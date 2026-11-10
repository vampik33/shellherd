import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api/herdr_client.dart';

/// Events that can change something in [HerdrSnapshot]. Output and layout
/// are not here: the lists do not show them.
const _lifecycle = [
  Subscription.lifecycle('workspace.created'),
  Subscription.lifecycle('workspace.updated'),
  Subscription.lifecycle('workspace.renamed'),
  Subscription.lifecycle('workspace.moved'),
  Subscription.lifecycle('workspace.reordered'),
  Subscription.lifecycle('workspace.closed'),
  Subscription.lifecycle('workspace.focused'),
  Subscription.lifecycle('tab.created'),
  Subscription.lifecycle('tab.closed'),
  Subscription.lifecycle('tab.focused'),
  Subscription.lifecycle('tab.renamed'),
  Subscription.lifecycle('tab.moved'),
  Subscription.lifecycle('pane.created'),
  Subscription.lifecycle('pane.closed'),
  Subscription.lifecycle('pane.exited'),
  Subscription.lifecycle('pane.updated'),
  Subscription.lifecycle('pane.focused'),
  Subscription.lifecycle('pane.moved'),
  Subscription.lifecycle('pane.agent_detected'),
];

/// A pane can close between the snapshot and the subscribe, and herdr then
/// rejects the subscribe. A new snapshot fixes that; this many in a row
/// means that it does not.
const _maxRejections = 5;

/// Keeps a copy of the herdr session current, over one link.
///
/// Every event only marks the copy as old; the new state always comes from
/// a whole `session.snapshot`, so events need no separate handling. A
/// snapshot counts only if a subscription that covers its panes started
/// before it, because herdr does not replay earlier events. herdr has no
/// status event for all panes, so a change in the set of panes replaces the
/// subscription.
///
/// It also reads a snapshot every [refreshEvery]. herdr sends no event for
/// a renamed pane or a new working directory. And a stalled network never
/// ends a subscription, and dartssh2's keepalive has no reply deadline, so
/// only a request that gets no answer shows the stall.
class HerdrCache {
  HerdrCache(
    this._client, {
    required this.onSnapshot,
    this.debounce = defaultDebounce,
    this.refreshEvery = defaultRefreshEvery,
  });

  static const defaultDebounce = Duration(milliseconds: 150);
  static const defaultRefreshEvery = Duration(seconds: 15);

  final HerdrClient _client;

  /// Gets each new state, oldest first.
  final void Function(HerdrSnapshot) onSnapshot;

  /// How long to collect events before reading a new snapshot. It does not
  /// restart with each event, so busy agents cannot hold the update back.
  final Duration debounce;

  final Duration refreshEvery;

  final _lost = Completer<Object>();
  StreamSubscription<HerdrEvent>? _events;
  Set<String>? _watched;
  Timer? _timer;
  Timer? _refreshTimer;
  var _syncing = false;
  var _stale = false;
  var _closed = false;

  /// Completes with the cause when the copy can no longer be kept current.
  /// The owner then calls [close] and starts again on a new link.
  Future<Object> get lost => _lost.future;

  /// Subscribes and publishes the first snapshot. Throws a [HerdrException]
  /// if that fails; [close] still has to run.
  Future<void> start() async {
    await _syncExclusive();
    if (_closed) return;
    _refreshTimer = Timer.periodic(refreshEvery, (_) => _schedule());
  }

  Future<void> _refresh() async {
    _timer = null;
    try {
      await _syncExclusive();
    } catch (e) {
      _lose(e);
    }
  }

  Future<void> _syncExclusive() async {
    _syncing = true;
    try {
      await _sync();
    } finally {
      _syncing = false;
      if (_stale) _schedule();
    }
  }

  /// An event during a snapshot leaves [_stale] set, so that another
  /// snapshot follows.
  Future<void> _sync() async {
    var rejections = 0;
    while (!_closed) {
      _stale = false;
      final snapshot = await _client.snapshot();
      if (_closed) return;
      final panes = {for (final p in snapshot.panes) p.id};
      if (setEquals(panes, _watched)) {
        onSnapshot(snapshot);
        return;
      }
      try {
        await _watch(panes);
      } on HerdrApiException catch (e) {
        if (e.code != 'pane_not_found' || ++rejections >= _maxRejections) {
          rethrow;
        }
      }
    }
  }

  /// Replaces the subscription. The old one stays until the new one runs,
  /// so that no event falls between them.
  Future<void> _watch(Set<String> panes) async {
    final subscription = await _client.subscribe([
      ..._lifecycle,
      for (final id in panes) Subscription.agentStatus(id),
    ]);
    if (_closed) {
      await subscription.close();
      return;
    }
    final old = _events;
    _events = subscription.events.listen(
      (_) {
        _stale = true;
        _schedule();
      },
      onError: _lose,
      onDone: () => _lose(const HerdrConnectionClosedException('events')),
    );
    _watched = panes;
    await old?.cancel();
  }

  void _schedule() {
    if (_closed || _syncing || _timer != null) return;
    _timer = Timer(debounce, _refresh);
  }

  void _lose(Object cause) {
    if (!_closed && !_lost.isCompleted) _lost.complete(cause);
  }

  /// Stops updates and releases the subscription. Nothing is published
  /// after this.
  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _refreshTimer?.cancel();
    await _events?.cancel();
  }
}
