import 'dart:async';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../ssh/host.dart';
import '../ssh/ssh_connector.dart';
import 'api/herdr_client.dart';
import 'api/hc_client.dart';
import 'hc_cache.dart';
import 'hc_link.dart';
import 'herdr_cache.dart';
import 'herdr_link.dart';
import 'pane_stream.dart';
import 'server_api.dart';
import 'transcript/transcript_stream.dart';

/// Where a [HerdrConnection] stands. The top bar of the herdr screens shows
/// it.
sealed class LinkState {
  const LinkState();
}

/// Not connected, because no one asked or the user left.
class LinkOffline extends LinkState {
  const LinkOffline();
}

/// The first attempt: SSH login and the herdr ping.
class LinkConnecting extends LinkState {
  const LinkConnecting();
}

/// SSH works and herdr answered; reading the session.
class LinkSyncing extends LinkState {
  const LinkSyncing();
}

/// Events arrive and the snapshot is current.
class LinkLive extends LinkState {
  const LinkLive();
}

/// The link failed and the app tries again by itself.
class LinkReconnecting extends LinkState {
  const LinkReconnecting(this.cause, {this.retryAt});
  final Object cause;

  /// When the next attempt starts; null while an attempt runs.
  final DateTime? retryAt;
}

/// SSH works, but nothing listens on the herdr socket. Only
/// [HerdrConnection.connect] tries again.
class LinkNoServer extends LinkState {
  const LinkNoServer(this.cause);
  final Object cause;
}

/// Trying again cannot help: the login or the host key was refused, or
/// herdr speaks something this build cannot read. Only
/// [HerdrConnection.connect] tries again.
class LinkFailed extends LinkState {
  const LinkFailed(this.cause);
  final Object cause;
}

/// Makes the cache that keeps the snapshot of one link current.
typedef CacheFactory = SnapshotCache Function(
  void Function(HerdrSnapshot) onSnapshot, {
  required Duration debounce,
  required Duration refreshEvery,
});

/// One open link to a herdr server or to the Herdr app.
class OpenLink {
  const OpenLink({
    required this.api,
    required this.cache,
    required this.done,
    required this.close,
    this.screens,
    this.transcripts,
  });

  /// A link to herdr.
  factory OpenLink.herdr(
    HerdrClient client, {
    required Future<void> done,
    required void Function() close,
    ScreenOpener? screens,
    TranscriptOpener? transcripts,
  }) => OpenLink(
    api: HerdrPaneApi(client),
    screens: screens,
    transcripts: transcripts,
    cache: (onSnapshot, {required debounce, required refreshEvery}) =>
        HerdrCache(
          client,
          onSnapshot: onSnapshot,
          debounce: debounce,
          refreshEvery: refreshEvery,
        ),
    done: done,
    close: close,
  );

  /// A link to the Herdr app. herdr-core sends heartbeats, so its cache
  /// needs no periodic read.
  factory OpenLink.hc(
    HcClient client, {
    required Future<void> done,
    required void Function() close,
  }) => OpenLink(
    api: HcPaneApi(client),
    cache: (onSnapshot, {required debounce, required refreshEvery}) =>
        HcCache(client, onSnapshot: onSnapshot, debounce: debounce),
    done: done,
    close: close,
  );

  final PaneApi api;

  /// Starts live screen streams of panes; null where the server has none.
  final ScreenOpener? screens;

  /// Starts reads of agent transcripts; null where the server reports
  /// none.
  final TranscriptOpener? transcripts;

  final CacheFactory cache;

  /// Completes, with or without an error, when the link ends.
  final Future<void> done;
  final void Function() close;
}

/// Opens a link, or throws.
typedef LinkOpener = Future<OpenLink> Function();

/// Opens a link to [host] over a new SSH connection, which it owns.
LinkOpener sshLinkOpener(
  SshConnector connector,
  Host host, {
  Duration timeout = const Duration(seconds: 15),
}) => () async {
  final ssh = await connector.open(host);
  try {
    switch (host.herdrKind) {
      case HerdrKind.herdr:
        final link = await HerdrLink.connect(
          ssh,
          session: host.herdrSession,
          socketPath: host.herdrSocket,
          timeout: timeout,
        );
        return OpenLink.herdr(
          link.client,
          screens: sshScreenOpener(ssh, link.socketPath, timeout: timeout),
          transcripts: sshTranscriptOpener(ssh, timeout: timeout),
          done: ssh.done,
          close: ssh.close,
        );
      case HerdrKind.herdrApp:
        final client = await connectHc(
          ssh,
          session: host.herdrSession,
          socketPath: host.herdrSocket,
          timeout: timeout,
        );
        return OpenLink.hc(client, done: ssh.done, close: ssh.close);
    }
  } catch (_) {
    ssh.close();
    rethrow;
  }
};

/// 1, 2, 4, 8, 16 s, then 30 s for each further failure in a row.
Duration linkBackoff(int failures) =>
    Duration(seconds: min(30, 1 << min(failures, 5)));

/// The link to one herdr server: opens it, keeps a [snapshot] of the session
/// current, and reconnects when the link drops. The [snapshot] survives a
/// lost link, for the lists to show it dimmed.
class HerdrConnection {
  HerdrConnection(
    this._open, {
    this.refreshEvery = HerdrCache.defaultRefreshEvery,
    this.backoff = linkBackoff,
    this.debounce = HerdrCache.defaultDebounce,
  });

  final LinkOpener _open;

  /// See [HerdrCache.refreshEvery].
  final Duration refreshEvery;

  /// The wait before the next attempt, by the failures in a row so far.
  final Duration Function(int failures) backoff;

  /// See [HerdrCache.debounce].
  final Duration debounce;

  final state = ValueNotifier<LinkState>(const LinkOffline());

  /// The last state of the session; null until the first sync.
  final snapshot = ValueNotifier<HerdrSnapshot?>(null);

  /// The live link; null while there is none.
  OpenLink? _live;

  /// The pane requests of the live link, for the open screen; null while
  /// there is none.
  PaneApi? get api => _live?.api;

  /// The screen streams of the live link, for the open screen; null while
  /// there is none, or where the server has none.
  ScreenOpener? get screens => _live?.screens;

  /// The transcript reads of the live link, for the open screen; null while
  /// there is none, or where the server has none.
  TranscriptOpener? get transcripts => _live?.transcripts;

  /// Identifies the current run of [_run]. An older run sees that it is
  /// over and stops without touching the state.
  var _runId = 0;
  Completer<void>? _wake;
  Completer<Object>? _stop;

  /// Starts connecting. While a retry waits, it tries at once. It does
  /// nothing during an attempt or when live.
  void connect() {
    switch (state.value) {
      case LinkOffline() || LinkNoServer() || LinkFailed():
        unawaited(_run(++_runId));
      case LinkReconnecting():
        _endWait();
      case LinkConnecting() || LinkSyncing() || LinkLive():
        break;
    }
  }

  /// Drops the link and stays offline, keeping the [snapshot].
  void close() {
    _runId++;
    _live = null;
    _endWait();
    if (_stop case final stop? when !stop.isCompleted) stop.complete('closed');
    state.value = const LinkOffline();
  }

  void dispose() {
    close();
    state.dispose();
    snapshot.dispose();
  }

  void _endWait() {
    _wake?.complete();
    _wake = null;
  }

  Future<void> _run(int id) async {
    bool current() => id == _runId;
    var failures = 0;
    state.value = const LinkConnecting();
    while (current()) {
      final stop = _stop = Completer<Object>();
      OpenLink? link;
      SnapshotCache? cache;
      Object cause;
      try {
        link = await _open();
        if (!current()) return;
        state.value = const LinkSyncing();
        cache = link.cache(
          (s) {
            if (current()) snapshot.value = s;
          },
          debounce: debounce,
          refreshEvery: refreshEvery,
        );
        await cache.start();
        if (!current()) return;
        failures = 0;
        _live = link;
        state.value = const LinkLive();
        // The first of these to complete is the reason the link ended.
        cause = await Future.any([
          stop.future,
          cache.lost,
          link.done.then<Object>(
            (_) => const HerdrConnectionClosedException('link'),
            onError: (Object e) => e,
          ),
        ]);
      } catch (e) {
        cause = e;
      } finally {
        if (identical(_live, link)) _live = null;
        await cache?.close();
        link?.close();
      }
      if (!current()) return;
      final finalState = _finalState(cause);
      if (finalState != null) {
        state.value = finalState;
        return;
      }
      await _waitToRetry(cause, failures++);
      if (!current()) return;
      state.value = LinkReconnecting(cause);
    }
  }

  /// The state to stop in when a link fails with [error]; null to retry.
  static LinkState? _finalState(Object error) => switch (error) {
    SshHostKeyChanged() ||
    SshHostKeyRejected() ||
    SshAuthFailed() ||
    SshSecretsUnreadable() ||
    SshTailscaleCheckNeeded() => LinkFailed(error),
    HerdrProtocolException() => LinkFailed(error),
    HerdrConnectException(cause: SSHChannelOpenError()) => LinkNoServer(error),
    _ => null,
  };

  Future<void> _waitToRetry(Object cause, int failures) async {
    final delay = backoff(failures);
    final wake = _wake = Completer<void>();
    final timer = Timer(delay, () {
      if (identical(_wake, wake)) _endWait();
    });
    state.value = LinkReconnecting(cause, retryAt: DateTime.now().add(delay));
    await wake.future;
    timer.cancel();
  }
}
