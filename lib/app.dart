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
import 'ui/host_status.dart';
import 'ui/palette.dart';
import 'ui/tailscale_check_dialog.dart';

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

  /// Tells the host list when it is in view again.
  final routes = RouteObserver<ModalRoute<void>>();

  /// How the host list checks that a host is online.
  HostProbe probeHost = sshPortOpen;

  /// How often the host list checks while it is in view.
  Duration probeEvery = const Duration(seconds: 30);

  /// The first-use prompt comes from the connector, not from a screen.
  final navigatorKey = GlobalKey<NavigatorState>();

  late final connector = SshConnector(
    knownHosts: knownHosts,
    keys: keys,
    askTrust: (host, key) =>
        showHostKeyDialog(navigatorKey.currentContext!, host, key),
    // A watcher that stopped on this key can go on now.
    onTrusted: (_) => unawaited(syncNotify()),
    onTailscaleCheck: (check) {
      final context = navigatorKey.currentContext;
      if (context == null) return check.cancel();
      showTailscaleCheck(context, check);
      // A watcher that stopped on this check can go on now: Tailscale
      // remembers an approval for a while.
      unawaited(
        check.result.then((passed) {
          if (passed) unawaited(syncNotify());
        }),
      );
    },
  );

  /// [NotifyControl.sync] for callers that cannot show a failure.
  Future<void> syncNotify() async {
    try {
      await notify.sync();
    } catch (e) {
      debugPrint('shellherd: cannot update the watchers: $e');
    }
  }

  /// Saves whether the user disconnected [hostId], and updates the
  /// watchers if that changed. A failure shows on the screen open then.
  Future<void> setDisconnected(String hostId, bool value) async {
    try {
      if (await hosts.setDisconnected(hostId, value)) await syncNotify();
    } catch (e) {
      debugPrint('shellherd: cannot save the disconnect: $e');
      final context = navigatorKey.currentContext;
      if (context == null || !context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            'Cannot save the ${value ? 'disconnect' : 'reconnect'}: $e',
          ),
        ),
      );
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
    navigatorObservers: [services.routes],
    theme: _theme,
    home: HostListScreen(services),
  );
}

final _theme = ThemeData(
  fontFamily: uiFont,
  dividerColor: Graphite.border,
  colorScheme: const ColorScheme.dark(
    primary: Graphite.accent,
    onPrimary: Graphite.background,
    secondary: Graphite.cyan,
    onSecondary: Graphite.background,
    // The navigation bar's pill: neutral, as Herdr app marks a selection.
    secondaryContainer: Graphite.raised,
    onSecondaryContainer: Graphite.foreground,
    surface: Graphite.background,
    onSurface: Graphite.foreground,
    onSurfaceVariant: Graphite.muted,
    surfaceContainerLowest: Graphite.chrome,
    surfaceContainerLow: Graphite.canvas,
    surfaceContainer: Graphite.chrome,
    surfaceContainerHigh: Graphite.popover,
    surfaceContainerHighest: Graphite.raised,
    outline: Graphite.dim,
    outlineVariant: Graphite.border,
    error: Graphite.blocked,
    onError: Graphite.background,
    errorContainer: Graphite.errorContainer,
    onErrorContainer: Graphite.brightRed,
  ),
);
