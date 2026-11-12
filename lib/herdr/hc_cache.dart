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
class HcCache extends DebouncedCache {
  HcCache(
    this._client, {
    required super.onSnapshot,
    super.debounce = const Duration(milliseconds: 150),
    this.stallAfter = defaultStallAfter,
  });

  /// Two heartbeats missed, and some slack.
  static const defaultStallAfter = Duration(seconds: 35);

  final HcClient _client;

  final Duration stallAfter;

  HcSubscription? _subscription;
  Timer? _stall;

  @override
  Future<void> start() async {
    final subscription = _subscription = await _client.subscribe();
    if (closed) {
      await subscription.close();
      return;
    }
    subscription.notes.listen(
      _onNote,
      onError: lose,
      onDone: () => lose(const HerdrConnectionClosedException('events')),
    );
    unawaited(
      _client.done.then(
        (_) => lose(const HerdrConnectionClosedException('requests')),
      ),
    );
    _watchStall();
    await syncExclusive();
  }

  void _onNote(String method) {
    _watchStall();
    if (method == 'heartbeat') return;
    markStale();
  }

  void _watchStall() {
    _stall?.cancel();
    if (closed) return;
    _stall = Timer(
      stallAfter,
      () => lose(HerdrTimeoutException('heartbeat', stallAfter)),
    );
  }

  @override
  Future<void> sync() async {
    stale = false;
    // Both requests go out at once; an error of the second still reaches
    // the await below.
    final layoutRead = _client.layout()..ignore();
    final terminals = await _client.terminals();
    final layout = await layoutRead;
    if (!closed) onSnapshot(hcSnapshot(_client.hello, terminals, layout));
  }

  @override
  Future<void> close() async {
    await super.close();
    _stall?.cancel();
    await _subscription?.close();
  }
}
