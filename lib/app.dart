import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'notify/notifier.dart';
import 'notify/notify_control.dart';
import 'ssh/json_file.dart';
import 'ssh/host.dart';
import 'ssh/key_store.dart';
import 'ssh/known_hosts.dart';
import 'ssh/secret_store.dart';
import 'ssh/ssh_connector.dart';
import 'ui/host_key_dialog.dart';
import 'ui/host_list_screen.dart';
import 'ui/palette.dart';

/// The stores and the connector that the screens share.
class AppServices {
  AppServices({required Directory dataDir, required SecretStore secrets})
    : hosts = HostStore(JsonFile(File('${dataDir.path}/hosts.json'))),
      keys = KeyStore(secrets),
      knownHosts = KnownHosts(
        JsonFile(File('${dataDir.path}/known_hosts.json')),
      );

  final HostStore hosts;
  final KeyStore keys;
  final KnownHosts knownHosts;

  /// main sets the one of the platform before the first screen.
  NotifyControl notify = const NoNotify();

  /// The first-use prompt comes from the connector, not from a screen.
  final navigatorKey = GlobalKey<NavigatorState>();

  late final connector = SshConnector(
    knownHosts: knownHosts,
    keys: keys,
    askTrust: (host, key) =>
        showHostKeyDialog(navigatorKey.currentContext!, host, key),
    // A watcher that stopped on this key can go on now.
    onTrusted: (_) => unawaited(syncNotify()),
  );

  /// [NotifyControl.sync] for callers that cannot show a failure.
  Future<void> syncNotify() async {
    try {
      await notify.sync();
    } catch (e) {
      debugPrint('shellherd: cannot update the watchers: $e');
    }
  }

  /// For the watchers, which run with no one to ask: it trusts no new key.
  late final watchConnector = SshConnector(
    knownHosts: knownHosts,
    keys: keys,
    askTrust: (_, _) async => false,
  );

  /// Opens the pane of a tapped notification, over the screens open now.
  Future<void> openPane(PaneTarget target) async {
    final host = await hosts.get(target.hostId);
    final navigator = navigatorKey.currentState;
    if (host == null || navigator == null) return;
    navigator.popUntil((route) => route.isFirst);
    unawaited(navigator.push(herdrRoute(this, host, openPane: target.paneId)));
  }

  /// Removes [host] and what only it uses: its key or password, and the
  /// trusted server key unless another host connects to the same server.
  Future<void> removeHost(Host host) async {
    await hosts.remove(host.id);
    if (host.keyId case final keyId?) await keys.delete(keyId);
    await keys.deletePassword(host.id);
    final entry = KnownHosts.entryOf(host.address, host.port);
    final shared = (await hosts.list()).any(
      (h) => KnownHosts.entryOf(h.address, h.port) == entry,
    );
    if (!shared) await knownHosts.forget(host.address, host.port);
  }
}

class ShellherdApp extends StatelessWidget {
  const ShellherdApp(this.services, {super.key});

  final AppServices services;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'shellherd',
    navigatorKey: services.navigatorKey,
    theme: _theme,
    home: HostListScreen(services),
  );
}

final _theme = ThemeData(
  colorScheme: const ColorScheme.dark(
    primary: Mocha.blue,
    onPrimary: Mocha.base,
    secondary: Mocha.teal,
    onSecondary: Mocha.base,
    surface: Mocha.base,
    onSurface: Mocha.text,
    surfaceContainerHighest: Mocha.surface0,
    error: Mocha.red,
    onError: Mocha.base,
    errorContainer: Color(0xFF4A2A3A),
    onErrorContainer: Color(0xFFF5C2D0),
  ),
);
