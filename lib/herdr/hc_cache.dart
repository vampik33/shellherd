import 'dart:async';

import 'api/hc_client.dart';
import 'api/herdr_client.dart';
import 'hc_snapshot.dart';
import 'server_api.dart';

/// Keeps a copy of the Herdr app's session current, over one link.
///
/// As [HerdrCache] does, every change only marks the copy as old; the new
/// state comes from a whole read of the terminals and the layout. The
/// subscription starts before the first read, so no change falls between
/// them.
///
/// herdr-core sends a heartbeat every 15 s. A stalled network ends no
/// connection, so silence for [stallAfter] counts as a lost link.
class HcCache implements SnapshotCache {
  HcCache(
    this._client, {
    required this.onSnapshot,
    this.debounce = const Duration(milliseconds: 150),
    this.stallAfter = defaultStallAfter,
  });

  /// Two heartbeats missed, and some slack.
  static const defaultStallAfter = Duration(seconds: 35);

  final HcClient _client;

  /// Gets each new state, oldest first.
  final void Function(HerdrSnapshot) onSnapshot;

  /// How long to collect changes before the next read. It does not restart
  /// with each change, so busy agents cannot hold the update back.
  final Duration debounce;

  final Duration stallAfter;

  final _lost = Completer<Object>();
  HcSubscription? _subscription;
  Timer? _timer;
  Timer? _stall;
  var _syncing = false;
  var _stale = false;
  var _closed = false;

  @override
  Future<Object> get lost => _lost.future;

  @override
  Future<void> start() async {
    final subscription = _subscription = await _client.subscribe();
    if (_closed) {
      await subscription.close();
      return;
    }
    subscription.notes.listen(
      _onNote,
      onError: _lose,
      onDone: () => _lose(const HerdrConnectionClosedException('events')),
    );
    unawaited(
      _client.done.then(
        (_) => _lose(const HerdrConnectionClosedException('requests')),
      ),
    );
    _watchStall();
    await _syncExclusive();
  }

  void _onNote(String method) {
    _watchStall();
    if (method == 'heartbeat') return;
    _stale = true;
    _schedule();
  }

  void _watchStall() {
    _stall?.cancel();
    if (_closed) return;
    _stall = Timer(
      stallAfter,
      () => _lose(HerdrTimeoutException('heartbeat', stallAfter)),
    );
  }

  Future<void> _refresh() async {
    _timer = null;
    try {
      await _syncExclusive();
    } catch (e) {
      _lose(e);
    }
  }

  /// A change during a read leaves [_stale] set, so that another read
  /// follows.
  Future<void> _syncExclusive() async {
    _syncing = true;
    try {
      _stale = false;
      // Both requests go out at once; an error of the second still
      // reaches the await below.
      final layoutRead = _client.layout()..ignore();
      final terminals = await _client.terminals();
      final layout = await layoutRead;
      if (!_closed) onSnapshot(hcSnapshot(_client.hello, terminals, layout));
    } finally {
      _syncing = false;
      if (_stale) _schedule();
    }
  }

  void _schedule() {
    if (_closed || _syncing || _timer != null) return;
    _timer = Timer(debounce, _refresh);
  }

  void _lose(Object cause) {
    if (!_closed && !_lost.isCompleted) _lost.complete(cause);
  }

  @override
  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _stall?.cancel();
    await _subscription?.close();
  }
}
