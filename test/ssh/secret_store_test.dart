import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/ssh/host.dart';
import 'package:shellherd/ssh/json_file.dart';
import 'package:shellherd/ssh/key_store.dart';
import 'package:shellherd/ssh/known_hosts.dart';
import 'package:shellherd/ssh/secret_store.dart';
import 'package:shellherd/ssh/ssh_connector.dart';
import 'package:shellherd/ui/link_status.dart';

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SecureSecretStore on Android', () {
    final calls = <MethodCall>[];
    setUp(() {
      calls.clear();
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            throw PlatformException(code: 'Exception encountered');
          });
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });

    test('asks the plugin not to wipe the store, and fails as '
        'SecretStoreException', () async {
      final store = SecureSecretStore();
      final failed = throwsA(isA<SecretStoreException>());
      await expectLater(store.read('k'), failed);
      await expectLater(store.write('k', 'v'), failed);
      await expectLater(store.delete('k'), failed);
      await expectLater(store.readAll(), failed);
      expect(calls.map((c) => c.method), [
        'read',
        'write',
        'delete',
        'readAll',
      ]);
      for (final call in calls) {
        final options = (call.arguments as Map)['options'] as Map;
        expect(options['resetOnError'], 'false', reason: call.method);
      }
    });
  });

  group('SshConnector with an unreadable store', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('shellherd-'));
    tearDown(() => dir.delete(recursive: true));

    // A trusted host, so open() reads the store before any network.
    Future<SshConnector> connector() async {
      final knownHosts = KnownHosts(JsonFile(File('${dir.path}/kh.json')));
      await knownHosts.trust(
        'workbox.invalid',
        22,
        const HostKey('ssh-ed25519', 'SHA256:x'),
      );
      return SshConnector(
        knownHosts: knownHosts,
        keys: KeyStore(_FailingStore()),
        askTrust: (_, _) async => fail('a trusted host asks nothing'),
      );
    }

    for (final (auth, keyId) in [
      (SshAuth.key, 'k1'),
      (SshAuth.password, null),
    ]) {
      test('a ${auth.name} host fails as SshSecretsUnreadable', () async {
        final host = Host(
          id: 'h1',
          label: 'workbox',
          address: 'workbox.invalid',
          user: 'dev',
          auth: auth,
          keyId: keyId,
        );
        final c = await connector();
        try {
          await c.open(host);
          fail('opened');
        } on SshSecretsUnreadable catch (e) {
          final banner = sshFailureBanner(e, ('Retry', () {}));
          expect(banner.detail, startsWith('Nothing was deleted.'));
          expect(banner.action, isNotNull);
        }
      });
    }
  });
}

/// Fails every read; the connector reads nothing else.
class _FailingStore extends Fake implements SecretStore {
  @override
  Future<String?> read(String key) async =>
      throw const SecretStoreException('Keystore says no');
}
