/// Runs [SshConnector], [KeyStore] and [KnownHosts] against a throwaway
/// sshd on 127.0.0.1 (see test/support/test_sshd.dart).
/// Skipped when sshd is not installed.
@Tags(['sshd'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/ssh/host.dart';
import 'package:shellherd/ssh/json_file.dart';
import 'package:shellherd/ssh/key_store.dart';
import 'package:shellherd/ssh/known_hosts.dart';
import 'package:shellherd/ssh/ssh_connector.dart';

import '../support/memory_secret_store.dart';
import '../support/test_sshd.dart';

void main() {
  final skip = TestSshd.binary == null ? 'sshd is not installed' : null;

  late Directory dir;
  late TestSshd sshd;
  TestSshd? started;
  late KeyStore keys;
  late KnownHosts knownHosts;
  late String keyId;
  late List<HostKey> asked;

  /// Answers each trust prompt.
  late Future<bool> Function(HostKey key) answer;
  final open = <SSHClient>[];

  setUp(() async {
    if (skip != null) return;
    dir = await Directory.systemTemp.createTemp('shellherd-ssh-');
    sshd = started = await TestSshd.start();
    keys = KeyStore(MemorySecretStore());
    knownHosts = KnownHosts(JsonFile(File('${dir.path}/known_hosts.json')));
    keyId = await keys.generate();
    await sshd.authorize(await keys.publicLine(keyId));
    asked = [];
    answer = (_) async => true;
  });
  tearDown(() async {
    for (final c in open) {
      c.close();
    }
    open.clear();
    await started?.stop();
    started = null;
    if (skip == null) await dir.delete(recursive: true);
  });

  Host host({String? key}) => Host(
    id: 'h1',
    label: 'test',
    address: '127.0.0.1',
    port: sshd.port,
    user: Platform.environment['USER']!,
    keyId: key ?? keyId,
  );

  SshConnector connector({void Function(Host)? onTrusted}) => SshConnector(
    knownHosts: knownHosts,
    keys: keys,
    askTrust: (h, key) async {
      asked.add(key);
      return answer(key);
    },
    onTrusted: onTrusted,
    timeout: const Duration(seconds: 5),
  );

  Future<SSHClient> connect([Host? h]) async {
    final c = await connector().open(h ?? host());
    open.add(c);
    return c;
  }

  HostKey serverKey() => sshd.hostKey;

  /// Restarts sshd on the same address and port with a new host key: to a
  /// client this looks like a changed server key, or a MITM.
  Future<void> rotateHostKey() async {
    final port = sshd.port;
    await sshd.stop();
    sshd = started = await TestSshd.start(port: port);
    await sshd.authorize(await keys.publicLine(keyId));
  }

  group('SshConnector', skip: skip ?? false, () {
    test('first use asks once, stores the key, then logs in', () async {
      final ssh = await connect();
      expect(
        utf8.decode(await ssh.run('echo shellherd-ok')).trim(),
        'shellherd-ok',
      );
      expect(asked, [serverKey()]);
      expect(await knownHosts.lookup('127.0.0.1', sshd.port), serverKey());

      await connect();
      expect(asked, hasLength(1), reason: 'a known key does not ask again');
    });

    test('says when a key was trusted, only then', () async {
      final trusted = <String>[];
      answer = (_) async => false;
      final declining = connector(onTrusted: (h) => trusted.add(h.id));
      await expectLater(
        declining.open(host()),
        throwsA(isA<SshHostKeyRejected>()),
      );
      expect(trusted, isEmpty);

      answer = (_) async => true;
      open.add(await declining.open(host()));
      expect(trusted, ['h1']);
      expect(await knownHosts.lookup('127.0.0.1', sshd.port), serverKey());
      open.add(await declining.open(host()));
      expect(trusted, ['h1'], reason: 'a known key is not trusted again');
    });

    test('a declined key stops the connection and is not stored', () async {
      answer = (_) async => false;
      await expectLater(
        connect(),
        throwsA(
          isA<SshHostKeyRejected>().having(
            (e) => e.presented,
            'presented',
            serverKey(),
          ),
        ),
      );
      expect(await knownHosts.lookup('127.0.0.1', sshd.port), isNull);
    });

    test(
      'a changed server key stops without asking; forget asks again',
      () async {
        await connect();
        final trusted = serverKey();
        await rotateHostKey();
        expect(serverKey(), isNot(trusted));

        await expectLater(
          connect(),
          throwsA(
            isA<SshHostKeyChanged>()
                .having((e) => e.trusted, 'trusted', trusted)
                .having((e) => e.presented, 'presented', serverKey()),
          ),
        );
        expect(asked, [trusted], reason: 'no prompt for a changed key');
        expect(await knownHosts.lookup('127.0.0.1', sshd.port), trusted);

        await knownHosts.forget('127.0.0.1', sshd.port);
        await connect();
        expect(asked, [trusted, serverKey()]);
      },
    );

    test(
      'two first-use prompts for different keys cannot swap the trust',
      () async {
        final prompts = <Completer<bool>>[];
        answer = (_) {
          final c = Completer<bool>();
          prompts.add(c);
          return c.future;
        };
        Future<void> promptCount(int n) async {
          for (var i = 0; prompts.length < n; i++) {
            if (i > 250) fail('no prompt $n');
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
        }

        // Prompt 1 shows key A; the server then changes to key B and a
        // second open() shows prompt 2 for B. Both prompts are open at once.
        final first = connector().open(host());
        await promptCount(1);
        final keyA = serverKey();
        await rotateHostKey();
        final keyB = serverKey();
        final second = connector().open(host());
        await promptCount(2);
        expect(asked, [keyA, keyB]);

        Matcher changed(HostKey trusted, HostKey presented) => throwsA(
          isA<SshHostKeyChanged>()
              .having((e) => e.trusted, 'trusted', trusted)
              .having((e) => e.presented, 'presented', presented),
        );
        prompts[0].complete(true); // trusts A; the server now shows B
        await expectLater(first, changed(keyA, keyB));
        prompts[1].complete(true); // must not replace A with B
        await expectLater(second, changed(keyA, keyB));
        expect(await knownHosts.lookup('127.0.0.1', sshd.port), keyA);
      },
    );

    test('a key the server does not accept fails as SshAuthFailed', () async {
      final stranger = await keys.generate();
      await expectLater(
        connect(host(key: stranger)),
        throwsA(isA<SshAuthFailed>()),
      );
    });

    test('a host whose saved key is gone fails as SshAuthFailed', () async {
      await keys.delete(keyId);
      await expectLater(connect(), throwsA(isA<SshAuthFailed>()));
    });

    test('a closed port fails as SshNetworkException', () async {
      final port = sshd.port;
      await sshd.stop();
      started = null;
      await expectLater(
        connector().open(
          Host(
            id: 'h2',
            label: 'gone',
            address: '127.0.0.1',
            port: port,
            user: 'nobody',
            keyId: keyId,
          ),
        ),
        throwsA(isA<SshNetworkException>()),
      );
    });
  });

  group('KeyStore with OpenSSH', skip: skip ?? false, () {
    Future<String> sshKeygen(List<String> args) async {
      final r = await Process.run('ssh-keygen', args);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return r.stdout as String;
    }

    test('a generated key reads back in ssh-keygen as the same key', () async {
      final pemFile = File('${dir.path}/gen');
      final secrets = MemorySecretStore();
      final store = KeyStore(secrets);
      final id = await store.generate();
      await pemFile.writeAsString(secrets.values['ssh-key.$id']!);
      // ssh-keygen refuses a private key that others can read.
      await Process.run('chmod', ['600', pemFile.path]);
      final derived = (await sshKeygen(['-y', '-f', pemFile.path])).trim();
      // ssh-keygen -y prints "type base64 comment"; compare type and key.
      final ours = (await store.publicLine(id)).split(' ').take(2);
      expect(ours.join(' '), derived.split(' ').take(2).join(' '));
    });

    test('imports a passphrase-protected ssh-keygen key and logs in', () async {
      final path = '${dir.path}/imported';
      await sshKeygen([
        '-q',
        '-t',
        'ed25519',
        '-N',
        'pass phrase',
        '-C',
        'imp',
        '-f',
        path,
      ]);
      final pem = await File(path).readAsString();

      await expectLater(
        keys.importPem(pem, passphrase: 'wrong'),
        throwsA(isA<KeyImportException>()),
      );
      await expectLater(
        keys.importPem(pem),
        throwsA(isA<KeyImportException>()),
      );

      final id = await keys.importPem(pem, passphrase: 'pass phrase');
      expect(
        await keys.publicLine(id),
        (await File('$path.pub').readAsString()).trim(),
      );
      await sshd.authorize(await keys.publicLine(id));
      final ssh = await connect(host(key: id));
      expect(utf8.decode(await ssh.run('echo imported')).trim(), 'imported');
    });
  });
}
