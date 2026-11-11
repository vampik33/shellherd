/// Runs the Tailscale logins of [SshConnector] against a real SSH handshake
/// with a paramiko server on 127.0.0.1 that acts as Tailscale SSH (see
/// test/support/password_sshd.py). Skipped when python3 or paramiko is
/// missing.
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
final _checkUrl = Uri.parse('https://login.tailscale.com/a/test0123');

Future<void> main() async {
  final skip = await PasswordSshd.available()
      ? null
      : 'python3 with paramiko is missing';

  late Directory dir;
  late KeyStore keys;
  late KnownHosts knownHosts;
  PasswordSshd? sshd;
  final open = <SSHClient>[];

  setUp(() async {
    if (skip != null) return;
    dir = await Directory.systemTemp.createTemp('shellherd-ts-');
    keys = KeyStore(MemorySecretStore());
    knownHosts = KnownHosts(JsonFile(File('${dir.path}/known_hosts.json')));
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

  SshConnector connector({
    TailscaleCheckPrompt? onCheck,
    Duration checkTimeout = const Duration(seconds: 20),
  }) => SshConnector(
    knownHosts: knownHosts,
    keys: keys,
    askTrust: (_, _) async => true,
    onTailscaleCheck: onCheck,
    timeout: const Duration(seconds: 5),
    checkTimeout: checkTimeout,
  );

  /// A Tailscale host on a new server in [mode]. It has a saved password
  /// under its id, which must never be sent.
  Future<Host> serve(PasswordMode mode) async {
    final server = sshd = await PasswordSshd.start(mode, _password);
    final host = Host(
      id: 'h1',
      label: 'test',
      address: '127.0.0.1',
      port: server.port,
      user: 'dev',
      auth: SshAuth.tailscale,
    );
    await keys.savePassword(host.id, _password);
    return host;
  }

  Future<Object> failure(SshConnector connector, Host host) =>
      connector.open(host).then<Object>((c) {
        open.add(c);
        return 'logged in';
      }, onError: (Object e) => e);

  group('Tailscale login', skip: skip ?? false, () {
    test('logs in by the none method, with no check', () async {
      final checks = <TailscaleCheck>[];
      open.add(
        await connector(onCheck: checks.add)
            .open(await serve(PasswordMode.none)),
      );
      expect(sshd!.answers, ['none ok']);
      expect(checks, isEmpty);
    });

    test('a check goes to the prompt and the login waits for it', () async {
      final checks = <TailscaleCheck>[];
      final client = await connector(onCheck: checks.add)
          .open(await serve(PasswordMode.check));
      open.add(client);
      expect(sshd!.answers, ['none ok']);
      expect(checks, hasLength(1));
      expect(checks.single.url, _checkUrl);
      expect(checks.single.host.id, 'h1');
      expect(await checks.single.result, isTrue);
    });

    test('with no one to ask, a check fails at once', () async {
      final host = await serve(PasswordMode.stuck);
      final watch = Stopwatch()..start();
      final error = await failure(connector(), host);
      expect(error, isA<SshTailscaleCheckNeeded>());
      expect((error as SshTailscaleCheckNeeded).url, _checkUrl);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    });

    test('cancel gives up the login', () async {
      final host = await serve(PasswordMode.stuck);
      final results = <Future<bool>>[];
      final error = await failure(
        connector(
          onCheck: (check) {
            results.add(check.result);
            check.cancel();
          },
        ),
        host,
      );
      expect(error, isA<SshTailscaleCheckNeeded>());
      expect(await results.single, isFalse);
    });

    test('a check no one approves ends after checkTimeout', () async {
      final host = await serve(PasswordMode.stuck);
      final checks = <TailscaleCheck>[];
      final error = await failure(
        connector(
          onCheck: checks.add,
          checkTimeout: const Duration(seconds: 1),
        ),
        host,
      );
      expect(error, isA<SshTailscaleCheckNeeded>());
      expect(checks, hasLength(1));
      expect(await checks.single.result, isFalse);
    });

    test('a server without Tailscale SSH gets no password', () async {
      final error = await failure(connector(), await serve(PasswordMode.both));
      expect(error, isA<SshAuthFailed>());
      expect(sshd!.answers, isEmpty);
    });
  });

  group('tailscaleCheckUrl', () {
    test('finds the link of the Tailscale banner', () {
      expect(
        tailscaleCheckUrl(
          '# Tailscale SSH requires an additional check.\n'
          '# To authenticate, visit: https://login.tailscale.com/a/abc123\n',
        ),
        Uri.parse('https://login.tailscale.com/a/abc123'),
      );
    });

    test('ignores a banner with no https link', () {
      expect(tailscaleCheckUrl('Welcome to workbox'), isNull);
      expect(tailscaleCheckUrl('see http://example.com/x'), isNull);
      expect(tailscaleCheckUrl('https://'), isNull);
    });
  });
}
