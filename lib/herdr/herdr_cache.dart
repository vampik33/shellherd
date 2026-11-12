import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api/herdr_client.dart';
import 'server_api.dart';

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
class HerdrCache extends DebouncedCache {
  HerdrCache(
    this._client, {
    required super.onSnapshot,
    super.debounce = defaultDebounce,
    this.refreshEvery = defaultRefreshEvery,
  });

  static const defaultDebounce = Duration(milliseconds: 150);
  static const defaultRefreshEvery = Duration(seconds: 15);

  final HerdrClient _client;

  final Duration refreshEvery;

  StreamSubscription<HerdrEvent>? _events;
  Set<String>? _watched;
  Timer? _refreshTimer;

  /// Subscribes and publishes the first snapshot. Throws a [HerdrException]
  /// if that fails; [close] still has to run.
  @override
  Future<void> start() async {
    await syncExclusive();
    if (closed) return;
    _refreshTimer = Timer.periodic(refreshEvery, (_) => schedule());
  }

  @override
  Future<void> sync() async {
    var rejections = 0;
    while (!closed) {
      stale = false;
      final snapshot = await _client.snapshot();
      if (closed) return;
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
    if (closed) {
      await subscription.close();
      return;
    }
    final old = _events;
    _events = subscription.events.listen(
      (_) => markStale(),
      onError: lose,
      onDone: () => lose(const HerdrConnectionClosedException('events')),
    );
    _watched = panes;
    await old?.cancel();
  }

  /// Stops updates and releases the subscription. Nothing is published
  /// after this.
  @override
  Future<void> close() async {
    await super.close();
    _refreshTimer?.cancel();
    await _events?.cancel();
  }
}
