import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api/herdr_client.dart';
import 'server_api.dart';

/// What the app knows about the text of a pane.
class PaneView {
  const PaneView({this.text, this.gone = false, this.error});

  /// With escape sequences; null until the first read.
  final String? text;

  /// herdr no longer has this pane. No more reads follow.
  final bool gone;

  /// Why the last read failed; null after a read that worked.
  final HerdrException? error;
}

/// Reads one pane again and again, because herdr has no output stream. It
/// reads often while the text changes and rarely while it does not.
///
/// A failed read does not end the polling: the link can come back, with a
/// new api. [HerdrConnection] notices and repairs a lost link.
class PanePoller {
  PanePoller(
    this._api,
    this.paneId, {
    this.fast = defaultFast,
    this.slow = defaultSlow,
  }) : _wait = fast;

  static const defaultFast = Duration(milliseconds: 400);
  static const defaultSlow = Duration(seconds: 2);

  /// How much of the history one read brings.
  static const historyLines = 400;

  final PaneApi? Function() _api;
  final String paneId;
  final Duration fast;
  final Duration slow;

  final view = ValueNotifier(const PaneView());

  /// The read whose text [view] shows, numbered from 1 as reads start; 0
  /// before the first one worked.
  final shownRead = ValueNotifier(0);

  /// The reads started so far.
  int get readsStarted => _reads;
  var _reads = 0;

  var _source = ReadSource.recentUnwrapped;
  Duration _wait;
  Completer<void>? _wake;
  var _kicked = false;
  var _paused = false;
  var _closed = false;

  void start() => unawaited(_loop());

  ReadSource get source => _source;

  /// Which text to read. The next read starts at once.
  set source(ReadSource value) {
    _source = value;
    kick();
  }

  /// Reads at once and fast again, for example after input. Input that
  /// arrives during a read may be too late for it, so another read follows.
  void kick() {
    _kicked = true;
    _wait = fast;
    _endWait();
  }

  /// Stops the reads while the app is in the background.
  void pause() => _paused = true;

  void resume() {
    _paused = false;
    kick();
  }

  void dispose() {
    _closed = true;
    _endWait();
    view.dispose();
    shownRead.dispose();
  }

  Future<void> _loop() async {
    while (!_closed && !view.value.gone) {
      _kicked = false;
      if (!_paused) await _read();
      if (_closed || view.value.gone || _kicked) continue;
      await _sleep();
    }
  }

  Future<void> _read() async {
    final api = _api();
    if (api == null) {
      _wait = slow;
      return;
    }
    final source = _source;
    final read = ++_reads;
    try {
      final text = await api.read(
        paneId,
        source: source,
        lines: source == ReadSource.visible ? null : historyLines,
      );
      // The answer to the old question, after a switch of the source.
      if (_closed || source != _source) return;
      final current = view.value;
      final changed = text != current.text;
      if (changed) {
        _wait = fast;
      } else if (!_kicked) {
        _wait = _wait * 2 > slow ? slow : _wait * 2;
      }
      if (changed || current.error != null) {
        view.value = PaneView(text: text);
      }
      shownRead.value = read;
    } on HerdrException catch (e) {
      if (_closed) return;
      final gone = e is HerdrApiException && e.code == 'pane_not_found';
      _wait = slow;
      view.value = PaneView(
        text: view.value.text,
        gone: gone,
        error: gone ? null : e,
      );
    }
  }

  Future<void> _sleep() async {
    final wake = _wake = Completer<void>();
    final timer = _paused
        ? null
        : Timer(_wait, () {
            if (identical(_wake, wake)) _endWait();
          });
    await wake.future;
    timer?.cancel();
  }

  void _endWait() {
    _wake?.complete();
    _wake = null;
  }
}

/// Input that was never sent.
class PaneInputNotSent implements Exception {
  const PaneInputNotSent({required this.noLink});

  /// True without a link. False when the input behind a failed one is
  /// dropped; that failure has already been reported.
  final bool noLink;
}

/// Sends input to one pane, one request at a time and in the order given,
/// because each request opens its own channel and could overtake another.
///
/// When one fails, the input queued behind it is dropped: a key that arrives
/// late could answer a question that the user no longer sees.
class PaneSender {
  PaneSender(this._api, this.paneId, {required this.onSent});

  final PaneApi? Function() _api;
  final String paneId;

  /// Called after each input that herdr took.
  final VoidCallback onSent;

  Future<void> _last = Future.value();
  var _generation = 0;

  Future<void> keys(List<String> keys) =>
      _enqueue((api) => api.keys(paneId, keys));

  /// Submits [text]. An agent gets it through its prompt, a plain shell as
  /// typed text and Enter. Throws a [HerdrException] or [PaneInputNotSent].
  Future<void> prompt(String text, {required bool toAgent}) =>
      _enqueue((api) => api.submit(paneId, text, toAgent: toAgent));

  /// Drops all queued input, for when the user leaves the pane. A request
  /// that is already on its way cannot be called back.
  void cancel() => _generation++;

  Future<void> _enqueue(Future<void> Function(PaneApi) send) {
    final generation = _generation;
    final result = _last.then((_) async {
      if (generation != _generation) {
        throw const PaneInputNotSent(noLink: false);
      }
      try {
        final api = _api();
        if (api == null) throw const PaneInputNotSent(noLink: true);
        await send(api);
      } catch (_) {
        _generation++;
        rethrow;
      }
      onSent();
    });
    _last = result.catchError((Object _) {});
    return result;
  }
}
