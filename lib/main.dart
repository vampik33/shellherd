import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'notify/background_service.dart';
import 'notify/notifier.dart';
import 'notify/notify_control.dart';
import 'notify/watch_hub.dart';
import 'ssh/secret_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = AppServices(
    dataDir: await getApplicationSupportDirectory(),
    secrets: SecureSecretStore(),
  );
  runApp(ShellherdApp(services));
  // Notifications set up after the first screen, so they cannot hold it up.
  LocalNotifier? notifier;
  try {
    notifier = await LocalNotifier.init(onTap: services.openPane);
  } catch (e) {
    // For example a Linux desktop with no notification server.
    debugPrint('shellherd: no notifications: $e');
  }
  // The host's own OS: a debug build can emulate another target platform.
  final android = Platform.isAndroid;
  services.notify = notifyControl(services, notifier, android: android);
  if (await notifier?.launchTarget(android: android) case final target?) {
    await WidgetsBinding.instance.endOfFrame;
    unawaited(services.openPane(target));
  }
  // Watching starts again with the app; it does not ask for permission.
  await services.syncNotify();
}

/// Who watches the agents: the background service on [android], the app
/// itself where it has notifications, else nobody.
NotifyControl notifyControl(
  AppServices services,
  Notifier? notifier, {
  required bool android,
}) => switch (notifier) {
  _ when android => ServiceNotify(services.hosts),
  final notifier? => InProcessNotify(
    WatchHub.ssh(services.hosts, services.watchConnector, notifier),
  ),
  null => const NoNotify(),
};
