import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/app.dart';
import 'package:shellherd/main.dart';
import 'package:shellherd/notify/background_service.dart';
import 'package:shellherd/notify/notify_control.dart';

import '../support/memory_secret_store.dart';
import '../support/recording_notifier.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late AppServices services;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('shellherd-wiring-');
    services = AppServices(dataDir: dir, secrets: MemorySecretStore());
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await dir.delete(recursive: true);
  });

  group('on Android', () {
    test('the background service watches, with notifications', () {
      expect(
        notifyControl(services, RecordingNotifier(), android: true),
        isA<ServiceNotify>(),
      );
    });

    test('the background service watches, even with no notifier here', () {
      expect(notifyControl(services, null, android: true), isA<ServiceNotify>());
    });
  });

  group('on Linux', () {
    test('the app watches and notifies through its notifier', () {
      final notifier = RecordingNotifier();
      final control = notifyControl(services, notifier, android: false);
      expect(control, isA<InProcessNotify>());
      expect((control as InProcessNotify).hub.notifier, same(notifier));
    });

    test('nobody watches with no notification server', () {
      expect(notifyControl(services, null, android: false), isA<NoNotify>());
    });

    test('a debug build emulating Android still watches in the app', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final control = notifyControl(services, RecordingNotifier(), android: false);
      expect(control, isA<InProcessNotify>());
    });
  });
}
