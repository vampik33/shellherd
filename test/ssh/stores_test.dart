import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/ssh/host.dart';
import 'package:shellherd/ssh/ids.dart';
import 'package:shellherd/ssh/json_file.dart';
import 'package:shellherd/ssh/key_store.dart';
import 'package:shellherd/ssh/known_hosts.dart';

import '../support/memory_secret_store.dart';

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('shellherd-'));
  tearDown(() => dir.delete(recursive: true));

  File fileNamed(String name) => File('${dir.path}/$name');

  group('JsonFile', () {
    test('a missing file reads as an empty object', () async {
      expect(await JsonFile(fileNamed('a.json')).read(), isEmpty);
    });

    test('a corrupt file is an error, not an empty store', () async {
      fileNamed('a.json').writeAsStringSync('{"hosts": [');
      await expectLater(
        JsonFile(fileNamed('a.json')).read(),
        throwsFormatException,
      );
      fileNamed('b.json').writeAsStringSync('[1]');
      await expectLater(
        JsonFile(fileNamed('b.json')).read(),
        throwsFormatException,
      );
    });

    test('concurrent updates all land, and no temp file is left', () async {
      final f = JsonFile(fileNamed('sub/a.json'));
      await Future.wait([
        for (var i = 0; i < 20; i++) f.update((d) => d['k$i'] = i),
      ]);
      expect((await f.read()).length, 20);
      expect(Directory('${dir.path}/sub').listSync(), hasLength(1));
    });

    test('a failed update does not block the next one', () async {
      final f = JsonFile(fileNamed('a.json'));
      await expectLater(
        f.update((_) => throw StateError('boom')),
        throwsStateError,
      );
      await f.update((d) => d['ok'] = true);
      expect(await f.read(), {'ok': true});
    });
  });

  group('HostStore', () {
    Host host(String id, {String label = 'workbox', String? session}) => Host(
      id: id,
      label: label,
      address: 'workbox.lan',
      user: 'dev',
      keyId: 'k1',
      herdrSession: session,
    );

    test('saves, replaces in place, keeps order, and removes', () async {
      final store = HostStore(JsonFile(fileNamed('hosts.json')));
      await store.save(host('a'));
      await store.save(host('b', session: 'work'));
      await store.save(host('a', label: 'renamed'));
      final hosts = await store.list();
      expect(hosts.map((h) => h.id), ['a', 'b']);
      expect(hosts.first.label, 'renamed');
      expect(hosts.last.herdrSession, 'work');
      expect((await store.get('b'))!.port, 22);

      await store.remove('a');
      expect((await store.list()).map((h) => h.id), ['b']);
      expect(await store.get('a'), isNull);
    });

    test('the file holds no unset fields and round-trips', () async {
      final store = HostStore(JsonFile(fileNamed('hosts.json')));
      await store.save(host('a'));
      final json = jsonDecode(fileNamed('hosts.json').readAsStringSync());
      final saved = (json as Map)['hosts'][0] as Map;
      expect(saved.containsKey('herdrSession'), isFalse);
      expect(Host.fromJson(saved.cast()).toJson(), saved);
    });

    test('rejects an empty address and a bad port', () {
      expect(
        () => Host(id: 'x', label: 'l', address: '', user: 'u', keyId: 'k'),
        throwsArgumentError,
      );
      expect(
        () => Host(
          id: 'x',
          label: 'l',
          address: 'a',
          port: 70000,
          user: 'u',
          keyId: 'k',
        ),
        throwsArgumentError,
      );
    });

    test('a host saved before passwords loads as a key host', () {
      final old = host('a').toJson()..remove('auth');
      final loaded = Host.fromJson(old);
      expect(loaded.auth, SshAuth.key);
      expect(loaded.keyId, 'k1');
    });

    test('a password host has no key, and the file holds no secret', () async {
      final store = HostStore(JsonFile(fileNamed('hosts.json')));
      await store.save(
        Host(
          id: 'p',
          label: 'l',
          address: 'a',
          user: 'u',
          auth: SshAuth.password,
        ),
      );
      final saved = (await store.list()).single;
      expect(saved.auth, SshAuth.password);
      expect(saved.keyId, isNull);
      final json = jsonDecode(fileNamed('hosts.json').readAsStringSync());
      expect((json as Map)['hosts'][0], {
        'id': 'p',
        'label': 'l',
        'address': 'a',
        'port': 22,
        'user': 'u',
        'auth': 'password',
        'mosh': false,
        'moshServer': 'mosh-server',
        'notify': false,
      });
    });

    test('a key host needs a key, a password host none', () {
      expect(
        () => Host(id: 'x', label: 'l', address: 'a', user: 'u'),
        throwsArgumentError,
      );
      expect(
        () => Host(
          id: 'x',
          label: 'l',
          address: 'a',
          user: 'u',
          auth: SshAuth.password,
          keyId: 'k',
        ),
        throwsArgumentError,
      );
    });

    test('new ids are 32 hex characters and differ', () {
      final a = randomId();
      expect(a, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(randomId(), isNot(a));
    });
  });

  group('KnownHosts', () {
    const key = HostKey('ssh-ed25519', 'SHA256:abc');

    test('trust, lookup and forget by address and port', () async {
      final kh = KnownHosts(JsonFile(fileNamed('known_hosts.json')));
      expect(await kh.lookup('WorkBox.lan', 22), isNull);
      await kh.trust('WorkBox.lan', 22, key);
      expect(await kh.lookup('workbox.lan', 22), key); // case-insensitive
      expect(await kh.lookup('workbox.lan', 2222), isNull); // per port
      await kh.forget('workbox.lan', 22);
      expect(await kh.lookup('workbox.lan', 22), isNull);
    });

    test('trust never replaces a trusted key', () async {
      final kh = KnownHosts(JsonFile(fileNamed('known_hosts.json')));
      const other = HostKey('ssh-ed25519', 'SHA256:xyz');
      expect(await kh.trust('h', 22, key), key);
      expect(await kh.trust('h', 22, other), key);
      expect(await kh.lookup('h', 22), key);
    });

    test('an IPv6 address gets brackets so the port stays apart', () async {
      final kh = KnownHosts(JsonFile(fileNamed('known_hosts.json')));
      await kh.trust('fe80::1', 22, key);
      final json = jsonDecode(fileNamed('known_hosts.json').readAsStringSync());
      expect((json as Map).keys, ['[fe80::1]:22']);
      expect(await kh.lookup('fe80::1', 22), key);
    });
  });

  group('KeyStore', () {
    test('keeps a password per host, apart from the keys', () async {
      final secrets = MemorySecretStore();
      final keys = KeyStore(secrets);
      expect(await keys.password('h1'), isNull);
      await keys.savePassword('h1', 'pw 1');
      await keys.savePassword('h2', 'pw 2');
      expect(await keys.password('h1'), 'pw 1');
      expect(await keys.ids(), isEmpty, reason: 'a password is no key');
      await keys.deletePassword('h1');
      expect(await keys.password('h1'), isNull);
      expect(secrets.values, {'ssh-password.h2': 'pw 2'});
    });

    test('generates distinct ed25519 keys and lists them', () async {
      final secrets = MemorySecretStore()..values['other'] = 'x';
      final keys = KeyStore(secrets);
      final a = await keys.generate();
      final b = await keys.generate(comment: 'phone');
      expect(await keys.ids(), unorderedEquals([a, b]));
      final lineA = await keys.publicLine(a);
      expect(
        lineA,
        matches(RegExp(r'^ssh-ed25519 [A-Za-z0-9+/=]+ shellherd$')),
      );
      expect(await keys.publicLine(b), endsWith(' phone'));
      expect(await keys.publicLine(b), isNot(startsWith(lineA.split(' ')[1])));
      expect((await keys.identities(a)).single.type, 'ssh-ed25519');
    });

    test('delete removes the key', () async {
      final keys = KeyStore(MemorySecretStore());
      final id = await keys.generate();
      await keys.delete(id);
      expect(await keys.ids(), isEmpty);
      await expectLater(keys.identities(id), throwsStateError);
    });

    test('text that is not a key is a KeyImportException', () async {
      final keys = KeyStore(MemorySecretStore());
      await expectLater(
        keys.importPem('not a key'),
        throwsA(isA<KeyImportException>()),
      );
      expect(await keys.ids(), isEmpty);
    });
  });
}
