import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

    test('updateIf writes only when the change says so', () async {
      final path = fileNamed('a.json');
      final f = JsonFile(path);
      expect(await f.updateIf((d) => false), isFalse);
      expect(path.existsSync(), isFalse, reason: 'nothing written');
      expect(await f.updateIf((d) => (d['k'] = 1) == 1), isTrue);
      expect(await f.read(), {'k': 1});
      final written = path.lastModifiedSync();
      await f.updateIf((d) {
        d['k'] = 2; // changed in memory, but not written
        return false;
      });
      expect(await f.read(), {'k': 1});
      expect(path.lastModifiedSync(), written);
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
    Host host(
      String id, {
      String label = 'workbox',
      String? session,
      bool disconnected = false,
    }) => Host(
      id: id,
      label: label,
      address: 'workbox.lan',
      user: 'dev',
      keyId: 'k1',
      herdrSession: session,
      disconnected: disconnected,
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

    test('a host saved before the Herdr app loads as a herdr host', () {
      final old = host('a').toJson()..remove('herdrKind');
      expect(Host.fromJson(old).herdrKind, HerdrKind.herdr);
    });

    test('a Herdr app host round-trips', () async {
      final store = HostStore(JsonFile(fileNamed('hosts.json')));
      await store.save(
        Host(
          id: 'h',
          label: 'l',
          address: 'a',
          user: 'u',
          keyId: 'k',
          herdrKind: HerdrKind.herdrApp,
        ),
      );
      expect((await store.list()).single.herdrKind, HerdrKind.herdrApp);
    });

    test('a host saved before Disconnect loads as connected', () {
      final old = host('a').toJson()..remove('disconnected');
      expect(Host.fromJson(old).disconnected, isFalse);
    });

    test('only a connected host with notify on is watched', () {
      Host h({required bool notify, required bool disconnected}) => Host(
        id: 'a',
        label: 'l',
        address: 'a',
        user: 'u',
        keyId: 'k',
        notify: notify,
        disconnected: disconnected,
      );
      expect(h(notify: true, disconnected: false).watched, isTrue);
      expect(h(notify: true, disconnected: true).watched, isFalse);
      expect(h(notify: false, disconnected: false).watched, isFalse);
      expect(h(notify: false, disconnected: true).watched, isFalse);
    });

    test('setDisconnected changes one host in place and says if it changed, '
        'and the flag stays for the next store', () async {
      final path = fileNamed('hosts.json');
      final store = HostStore(JsonFile(path));
      await store.save(host('a'));
      await store.save(host('b', session: 'work'));

      expect(await store.setDisconnected('b', true), isTrue);
      expect(await store.setDisconnected('b', true), isFalse, reason: 'same');
      expect(await store.setDisconnected('gone', true), isFalse);
      final unchanged = path.readAsStringSync();
      expect(await store.setDisconnected('a', false), isFalse);
      expect(path.readAsStringSync(), unchanged);

      final hosts = await HostStore(JsonFile(path)).list();
      expect(hosts.map((h) => h.id), ['a', 'b']);
      expect(hosts.map((h) => h.disconnected), [false, true]);
      expect(hosts.last.herdrSession, 'work', reason: 'the rest is kept');

      expect(await store.setDisconnected('b', false), isTrue);
      expect((await store.get('b'))!.disconnected, isFalse);
    });

    test('a setDisconnected that runs with a save does not lose it', () async {
      final store = HostStore(JsonFile(fileNamed('hosts.json')));
      await store.save(host('a'));
      await Future.wait([
        store.setDisconnected('a', true),
        store.save(host('b')),
      ]);
      final hosts = await store.list();
      expect(hosts.map((h) => h.id), ['a', 'b']);
      expect(hosts.first.disconnected, isTrue);
    });

    test('a save over a saved host keeps its disconnect, a new host keeps '
        'its own', () async {
      final path = fileNamed('hosts.json');
      final store = HostStore(JsonFile(path));
      await store.save(host('a'));
      await store.setDisconnected('a', true);
      await store.save(host('a', label: 'renamed'));
      var saved = (await store.get('a'))!;
      expect(saved.label, 'renamed');
      expect(saved.disconnected, isTrue);

      await store.setDisconnected('a', false);
      await store.save(host('a', disconnected: true));
      expect((await store.get('a'))!.disconnected, isFalse);

      await store.save(host('b', disconnected: true));
      expect((await store.get('b'))!.disconnected, isTrue);

      // A host saved before Disconnect came has no flag: it is connected.
      final json = jsonDecode(path.readAsStringSync()) as Map;
      ((json['hosts'] as List).first as Map).remove('disconnected');
      path.writeAsStringSync(jsonEncode(json));
      await store.save(host('a', label: 'old', disconnected: true));
      saved = (await store.get('a'))!;
      expect(saved.label, 'old');
      expect(saved.disconnected, isFalse);
    });

    for (final value in [true, false]) {
      for (final saveFirst in [true, false]) {
        test('a save from an old copy and a setDisconnected($value) queued '
            'together both land, the save ${saveFirst ? 'first' : 'last'}', () async {
          final store = HostStore(JsonFile(fileNamed('hosts.json')));
          await store.save(host('a', disconnected: !value));
          final save = host('a', label: 'renamed', disconnected: !value);
          await Future.wait([
            if (saveFirst) store.save(save),
            store.setDisconnected('a', value),
            if (!saveFirst) store.save(save),
          ]);
          final saved = (await store.list()).single;
          expect(saved.label, 'renamed');
          expect(saved.disconnected, value);
        });
      }
    }

    test('any host goes through the file and back unchanged', () {
      // Seeded, so that a failure repeats.
      final random = Random(7);
      T pick<T>(List<T> values) => values[random.nextInt(values.length)];
      String? maybe(String value) => random.nextBool() ? value : null;
      for (var i = 0; i < 500; i++) {
        final auth = pick(SshAuth.values);
        final saved = Host(
          id: randomId(),
          label: pick(['workbox', 'ünï · 💻', ' x ']),
          address: pick(['workbox.lan', '10.0.0.2', 'fe80::1', 'box']),
          port: 1 + random.nextInt(65535),
          user: pick(['dev', 'root', 'a b']),
          auth: auth,
          keyId: auth == SshAuth.key ? randomId() : null,
          herdrKind: pick(HerdrKind.values),
          herdrSession: maybe('work'),
          herdrSocket: maybe('/run/herdr.sock'),
          mosh: random.nextBool(),
          moshServer: pick([Host.defaultMoshServer, '~/bin/mosh-server']),
          notify: random.nextBool(),
          disconnected: random.nextBool(),
        );
        final json = saved.toJson();
        final loaded = Host.fromJson(
          (jsonDecode(jsonEncode(json)) as Map).cast(),
        );
        expect(loaded.toJson(), json);
        expect(loaded.disconnected, saved.disconnected);
        expect(loaded.watched, saved.watched);
      }
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
        'herdrKind': 'herdr',
        'mosh': false,
        'moshServer': 'mosh-server',
        'notify': false,
        'disconnected': false,
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

    test('a Tailscale host has no key and round-trips', () async {
      final store = HostStore(JsonFile(fileNamed('hosts.json')));
      await store.save(
        Host(
          id: 't',
          label: 'l',
          address: 'workbox',
          user: 'u',
          auth: SshAuth.tailscale,
        ),
      );
      final saved = (await store.list()).single;
      expect(saved.auth, SshAuth.tailscale);
      expect(saved.keyId, isNull);
      expect(
        () => Host(
          id: 'x',
          label: 'l',
          address: 'a',
          user: 'u',
          auth: SshAuth.tailscale,
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
