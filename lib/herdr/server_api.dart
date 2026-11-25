import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'api/hc_client.dart';
import 'api/herdr_client.dart';

/// What a pane screen asks of the server: its text, and input to it.
///
/// Errors are [HerdrException]s; a pane that is gone is a
/// [HerdrApiException] with the code `pane_not_found`, a blocked agent one
/// with `agent_blocked`.
abstract interface class PaneApi {
  /// The text of [paneId]: the visible screen for [ReadSource.visible],
  /// else the screen with up to [lines] of history. With escape sequences
  /// where the server keeps them.
  Future<String> read(String paneId, {required ReadSource source, int? lines});

  /// Presses key names such as `esc`, `enter` or `ctrl+c`.
  Future<void> keys(String paneId, List<String> keys);

  /// Submits [text] with Enter: to the agent's prompt when [toAgent].
  Future<void> submit(String paneId, String text, {required bool toAgent});

  /// Tells the server that a person is looking at the agent of [paneId],
  /// so it stops being done on every client. Only while it is really on
  /// the screen, with the app in front.
  ///
  /// [acked] is the turn this view marked already: it is not marked again,
  /// so a "mark unread" from another client stays. [looking] is asked
  /// again right before the write: the pane can go while the server
  /// answers. [upTo] is the last turn whose text the screen shows: a later
  /// one stays done. Returns the turn marked, for the next call; null where
  /// the server has no turns.
  Future<int?> markSeen(
    String paneId, {
    int? acked,
    int? upTo,
    required bool Function() looking,
  });
}

/// Keeps a copy of the session current over one link.
abstract interface class SnapshotCache {
  /// Publishes the first snapshot. Throws a [HerdrException] if that
  /// fails; [close] still has to run.
  Future<void> start();

  /// Completes with the cause when the copy can no longer be kept current.
  Future<Object> get lost;

  /// Stops updates. Nothing is published after this.
  Future<void> close();
}

/// The read scheduling of a [SnapshotCache]: a change only marks the copy
/// [stale], and a whole read follows after [debounce]. Reads never overlap;
/// a change during a read leaves the copy stale, so that another read
/// follows.
abstract class DebouncedCache implements SnapshotCache {
  DebouncedCache({required this.onSnapshot, required this.debounce});

  /// Gets each new state, oldest first.
  final void Function(HerdrSnapshot) onSnapshot;

  /// How long to collect changes before the next read. It does not restart
  /// with each change, so busy agents cannot hold the update back.
  final Duration debounce;

  final _lost = Completer<Object>();
  Timer? _timer;
  var _syncing = false;
  var _closed = false;

  /// Set by a change; [sync] clears it before it reads.
  @protected
  var stale = false;

  @protected
  bool get closed => _closed;

  @override
  Future<Object> get lost => _lost.future;

  /// Reads the whole state and passes it to [onSnapshot], unless [closed].
  @protected
  Future<void> sync();

  @protected
  void markStale() {
    stale = true;
    schedule();
  }

  /// Runs [sync], with no other read at the same time.
  @protected
  Future<void> syncExclusive() async {
    _syncing = true;
    try {
      await sync();
    } finally {
      _syncing = false;
      if (stale) schedule();
    }
  }

  /// Reads after [debounce], unless a read is already due or running.
  @protected
  void schedule() {
    if (_closed || _syncing || _timer != null) return;
    _timer = Timer(debounce, _refresh);
  }

  Future<void> _refresh() async {
    _timer = null;
    try {
      await syncExclusive();
    } catch (e) {
      lose(e);
    }
  }

  @protected
  void lose(Object cause) {
    if (!_closed && !_lost.isCompleted) _lost.complete(cause);
  }

  @override
  @mustCallSuper
  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
  }
}

class HerdrPaneApi implements PaneApi {
  const HerdrPaneApi(this._client);

  final HerdrClient _client;

  @override
  Future<String> read(
    String paneId, {
    required ReadSource source,
    int? lines,
  }) => _client.paneRead(
    paneId,
    source: source,
    format: ReadFormat.ansi,
    lines: lines,
  );

  @override
  Future<void> keys(String paneId, List<String> keys) =>
      _client.paneSendKeys(paneId, keys);

  @override
  Future<void> submit(String paneId, String text, {required bool toAgent}) =>
      toAgent
      ? _client.agentPrompt(paneId, text)
      : _client.paneSendInput(paneId, text: text, keys: const ['enter']);

  /// herdr marks a pane seen only when its own client focuses it, which
  /// would move the focus on the PC.
  @override
  Future<int?> markSeen(
    String paneId, {
    int? acked,
    int? upTo,
    required bool Function() looking,
  }) async => null;
}

/// Panes of the Herdr app are terminals of herdr-core, the pane id their
/// address. herdr-core keeps no colours in what it reads, and pastes text
/// the same way for an agent and for a shell.
class HcPaneApi implements PaneApi {
  const HcPaneApi(this._client);

  final HcClient _client;

  @override
  Future<String> read(
    String paneId, {
    required ReadSource source,
    int? lines,
  }) => _client.read(
    paneId,
    lines: source == ReadSource.visible ? 0 : lines ?? 0,
  );

  @override
  Future<void> keys(String paneId, List<String> keys) =>
      _client.keys(paneId, keys);

  /// herdr-core pastes into whatever runs in front, so text for an agent
  /// that has quit to its shell would run as commands. The core drops the
  /// status when the program leaves; the check here asks it just before the
  /// send. It is not atomic: `terminal.send`'s `if` takes only idle or
  /// working, and a finished Claude Code says `done`.
  @override
  Future<void> submit(
    String paneId,
    String text, {
    required bool toAgent,
  }) async {
    if (toAgent && (await _client.terminal(paneId)).status == null) {
      throw const HerdrApiException(
        'terminal.send',
        'agent_not_ready',
        'no program reports a status',
      );
    }
    await _client.send(paneId, text);
  }

  /// Raises the `herdr.seen` label to the agent's turn, as the Herdr app
  /// does for the agent a person looks at; also when the label is missing,
  /// so that terminals started elsewhere join. Never lowers it: that is
  /// "mark unread" on another client.
  @override
  Future<int?> markSeen(
    String paneId, {
    int? acked,
    int? upTo,
    required bool Function() looking,
  }) async {
    final t = await _client.terminal(paneId);
    if (t.status == null) return acked;
    final turn = upTo == null ? t.turn : min(upTo, t.turn);
    final seen = t.seen;
    final marked = (seen != null && seen >= turn) ||
        (acked != null && acked >= turn);
    if (marked) return turn;
    if (!looking()) return acked;
    await _client.label(paneId, {HcTerminal.seenLabel: '$turn'});
    return turn;
  }
}
