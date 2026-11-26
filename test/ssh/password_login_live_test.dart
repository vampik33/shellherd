/// Runs the password logins of [SshConnector] against a real SSH handshake
/// with a paramiko server on 127.0.0.1 (see test/support/password_sshd.py).
/// Skipped when python3 or paramiko is missing.
@Tags(['sshd'])
library;

import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/ssh/host.dart';
import 'package:shellherd/ssh/json_file.dart';
import 'package:shellherd/ssh/key_store.dart';
import 'package:shellherd/ssh/known_hosts.dart';
import 'package:shellherd/ssh/ssh_connector.dart';

import '../support/memory_secret_store.dart';
import '../support/password_sshd.dart';

const _password = 'correct horse';

Future<void> main() async {
  final skip = await PasswordSshd.available()
      ? null
      : 'python3 with paramiko is missing';

  late Directory dir;
  late KeyStore keys;
  late SshConnector connector;
  late List<HostKey> asked;
  PasswordSshd? sshd;
  final open = <SSHClient>[];

  setUp(() async {
    if (skip != null) return;
    dir = await Directory.systemTemp.createTemp('shellherd-pw-');
    keys = KeyStore(MemorySecretStore());
    asked = [];
    connector = SshConnector(
      knownHosts: KnownHosts(JsonFile(File('${dir.path}/known_hosts.json'))),
      keys: keys,
      askTrust: (_, key) async {
        asked.add(key);
        return true;
      },
      timeout: const Duration(seconds: 5),
    );
  });
  tearDown(() async {
    for (final c in open) {
      c.close();
    }
    open.clear();
    await sshd?.stop();
    sshd = null;
    if (skip == null) await dir.delete(recursive: true);
  });

  /// A password host on a new server in [mode], with [saved] as its saved
  /// password.
  Future<Host> serve(PasswordMode mode, {String? saved = _password}) async {
    final server = sshd = await PasswordSshd.start(mode, _password);
    final host = Host(
      id: 'h1',
      label: 'test',
      address: '127.0.0.1',
      port: server.port,
      user: 'dev',
      auth: SshAuth.password,
    );
    if (saved != null) await keys.savePassword(host.id, saved);
    return host;
  }

  Future<void> logsIn(Host host) async => open.add(await connector.open(host));

  Future<void> refused(Host host) async {
    final error = await connector.open(host).then<Object>((c) {
      open.add(c);
      return 'logged in';
    }, onError: (Object e) => e);
    expect(error, isA<SshAuthFailed>());
    expect('$error', isNot(contains(_password)));
  }

  group('password login', skip: skip ?? false, () {
    test('by the password method, after the first-use key prompt', () async {
      final host = await serve(PasswordMode.password);
      await logsIn(host);
      expect(await sshd!.answered(1), ['password ok']);
      expect(asked, hasLength(1));
      await logsIn(host);
      expect(asked, hasLength(1), reason: 'the key is trusted now');
    });

    test('by keyboard-interactive', () async {
      await logsIn(await serve(PasswordMode.kbdint));
      expect(await sshd!.answered(1), ['kbdint 1 ok']);
    });

    test('a server with both methods gets the password once', () async {
      await logsIn(await serve(PasswordMode.both));
      expect(await sshd!.answered(1), ['password ok']);
    });

    test('a wrong password is tried once per method', () async {
      await refused(await serve(PasswordMode.both, saved: 'wrong'));
      expect(await sshd!.settled(), ['password bad', 'kbdint 1 bad']);
    });

    test('a code prompt after the password gets no answer', () async {
      await refused(await serve(PasswordMode.otp));
      expect(
        await sshd!.settled(),
        ['kbdint 1 more'],
        reason: 'the password only',
      );
    });

    test('a round of two prompts gets no password', () async {
      await refused(await serve(PasswordMode.two));
      expect(await sshd!.settled(), isEmpty);
    });

    test('no saved password: refused without asking the server', () async {
      await refused(await serve(PasswordMode.password, saved: null));
      expect(await sshd!.settled(), isEmpty);
    });
  });
}
