import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../herdr/herdr_connection.dart';
import '../ssh/host.dart';
import '../ssh/ssh_connector.dart';
import 'agent_watcher.dart';
import 'notifier.dart';

/// One [AgentWatcher] for each saved host that has [Host.notify] on.
class WatchHub {
  WatchHub({
    required this.loadHosts,
    required this.connect,
    required this.notifier,
  });

  /// Watches the hosts of [hosts], each over its own SSH connection.
  factory WatchHub.ssh(
    HostStore hosts,
    SshConnector connector,
    Notifier notifier,
  ) => WatchHub(
    loadHosts: hosts.list,
    connect: (host) => HerdrConnection(
      sshLinkOpener(connector, host),
      refreshEvery: refreshEvery,
    ),
    notifier: notifier,
  );

  /// The lists read a snapshot every 15 s; a watcher, which may run all
  /// day, less often. Events still bring each status change at once.
  static const refreshEvery = Duration(seconds: 60);

  final Future<List<Host>> Function() loadHosts;

  /// A new connection to [Host]; the watcher owns it.
  final HerdrConnection Function(Host) connect;
  final Notifier notifier;

  /// One line per watched host, for the permanent notification.
  final summary = ValueNotifier<String>('');

  final _watchers = <String, AgentWatcher>{};
  PaneTarget? _shown;
  var _reload = Future<void>.value();
  var _disposed = false;

  /// The hosts that are watched now.
  int get count => _watchers.length;

  /// Reads the saved hosts again and starts, stops or restarts watchers to
  /// match. A host whose settings changed gets a new watcher; a kept one
  /// that stopped, for example on a server key trusted only since, tries
  /// again. Calls run one after another; a failed one does not stop the
  /// next.
  Future<void> reload() {
    final next = _reload.then((_) => _apply());
    _reload = next.catchError((Object _) {});
    return next;
  }

  Future<void> _apply() async {
    final hosts = [
      for (final h in await loadHosts())
        if (h.notify) h,
    ];
    if (_disposed) return;
    final wanted = {for (final h in hosts) h.id: h};
    for (final MapEntry(key: id, value: watcher) in _watchers.entries.toList()) {
      final host = wanted[id];
      if (host != null && _settings(host) == _settings(watcher.host)) {
        watcher.connection.connect();
      } else {
        _stop(id);
      }
    }
    for (final host in hosts) {
      if (_watchers.containsKey(host.id)) continue;
      final watcher = _watchers[host.id] = AgentWatcher(
        host,
        connect(host),
        notifier: notifier,
      );
      watcher.connection.state.addListener(_summarize);
      watcher.start();
      watcher.shownPane = _paneOf(host.id);
    }
    _summarize();
  }

  static String _settings(Host host) => jsonEncode(host.toJson());

  void _stop(String id) {
    final watcher = _watchers.remove(id)!;
    watcher.connection.state.removeListener(_summarize);
    watcher.dispose();
  }

  /// The pane that the user has on the screen, or null.
  set shown(PaneTarget? target) {
    _shown = target;
    for (final watcher in _watchers.values) {
      watcher.shownPane = _paneOf(watcher.host.id);
    }
  }

  String? _paneOf(String hostId) =>
      _shown?.hostId == hostId ? _shown!.paneId : null;

  void _summarize() {
    summary.value = [
      for (final w in _watchers.values)
        '${w.host.label}: ${_stateText(w.connection.state.value)}',
    ].join('\n');
  }

  static String _stateText(LinkState state) => switch (state) {
    LinkLive() => 'watching',
    LinkOffline() || LinkConnecting() || LinkSyncing() => 'connecting',
    LinkReconnecting() => 'no link, retrying',
    LinkNoServer() => 'herdr is not running',
    LinkFailed() => 'stopped, open the host in the app',
  };

  void dispose() {
    _disposed = true;
    for (final id in _watchers.keys.toList()) {
      _stop(id);
    }
    summary.dispose();
  }
}
