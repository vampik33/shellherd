/// Runs the password logins of [SshConnector] against real OpenSSH that
/// checks the password through PAM, in a Docker container (see
/// test/support/docker_sshd.dart). Skipped when Docker does not answer.
/// The first run builds the image, which needs the network.
@Tags(['docker'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/ssh/host.dart';
import 'package:shellherd/ssh/json_file.dart';
import 'package:shellherd/ssh/key_store.dart';
import 'package:shellherd/ssh/known_hosts.dart';
import 'package:shellherd/ssh/ssh_connector.dart';

import '../support/docker_sshd.dart';
import '../support/memory_secret_store.dart';

const _password = 'pam test pw';

Future<void> main() async {
  final skip = await DockerSshd.unavailable();

  late Directory dir;
  late KeyStore keys;
  late SshConnector connector;
  DockerSshd? sshd;
  final open = <SSHClient>[];

  setUpAll(() async {
    if (skip == null) await DockerSshd.build();
  });
  setUp(() async {
    if (skip != null) return;
    dir = await Directory.systemTemp.createTemp('shellherd-pam-');
    keys = KeyStore(MemorySecretStore());
    connector = SshConnector(
      knownHosts: KnownHosts(JsonFile(File('${dir.path}/known_hosts.json'))),
      keys: keys,
      askTrust: (_, _) async => true,
      // pam_unix waits about 2 s after a wrong password.
      timeout: const Duration(seconds: 15),
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
  Future<Host> serve(PamMode mode, {String saved = _password}) async {
    final server = sshd = await DockerSshd.start(mode, _password);
    final host = Host(
      id: 'h1',
      label: 'pam',
      address: '127.0.0.1',
      port: server.port,
      user: DockerSshd.user,
      auth: SshAuth.password,
    );
    await keys.savePassword(host.id, saved);
    return host;
  }

  /// Logs in and runs a command, so the session works past the login.
  Future<void> logsIn(Host host) async {
    final ssh = await connector.open(host);
    open.add(ssh);
    expect(utf8.decode(await ssh.run('id -un')).trim(), DockerSshd.user);
  }

  group('PAM login on real OpenSSH', skip: skip ?? false, () {
    test('by the password method', () async {
      await logsIn(await serve(PamMode.password));
      expect(await sshd!.logLines('Accepted password for dev'), hasLength(1));
    });

    test('by keyboard-interactive', () async {
      await logsIn(await serve(PamMode.kbdint));
      expect(
        await sshd!.logLines('Accepted keyboard-interactive/pam for dev'),
        hasLength(1),
      );
      expect(await sshd!.logLines('Failed'), isEmpty);
    });

    test('a server with both methods takes the password method', () async {
      await logsIn(await serve(PamMode.both));
      expect(await sshd!.logLines('Accepted password for dev'), hasLength(1));
      expect(await sshd!.logLines('Failed'), isEmpty);
    });

    test('a wrong password fails once per method', () async {
      final host = await serve(PamMode.both, saved: 'wrong');
      final error = await connector.open(host).then<Object>((c) {
        open.add(c);
        return 'logged in';
      }, onError: (Object e) => e);
      expect(error, isA<SshAuthFailed>());
      expect('$error', isNot(contains('wrong')));
      final log = await sshd!.log();
      expect(
        await sshd!.logLines('Failed password for dev'),
        hasLength(1),
        reason: log,
      );
      // sshd logs a refused keyboard-interactive round only as the PAM
      // failure.
      expect(
        await sshd!.logLines('PAM: Authentication failure for dev'),
        hasLength(1),
        reason: log,
      );
    });
  });
}
