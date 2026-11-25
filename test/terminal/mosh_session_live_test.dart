/// Runs [MoshShellSession] against a real mosh-server, started over a
/// throwaway sshd on 127.0.0.1. Skipped when sshd or mosh-server is missing.
@Tags(['sshd'])
@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/ssh/host.dart';
import 'package:shellherd/ssh/json_file.dart';
import 'package:shellherd/ssh/key_store.dart';
import 'package:shellherd/ssh/known_hosts.dart';
import 'package:shellherd/ssh/ssh_connector.dart';
import 'package:shellherd/terminal/mosh_shell_session.dart';
import 'package:xterm/xterm.dart';

import '../support/memory_secret_store.dart';
import '../support/mosh_servers.dart';
import '../support/poll.dart';
import '../support/test_sshd.dart';

Future<void> main() async {
  final hasMosh =
      (await Process.run('sh', ['-c', 'command -v mosh-server'])).exitCode == 0;
  final skip = TestSshd.binary == null
      ? 'sshd is not installed'
      : !hasMosh
      ? 'mosh-server is not installed'
      : null;

  group('MoshShellSession', skip: skip ?? false, () {
    late TestSshd sshd;
    late Host host;
    late Terminal terminal;
    late Set<int> before;
    final sessions = <MoshShellSession>[];

    setUp(() async {
      sshd = await TestSshd.start();
      host = Host(
        id: 'h1',
        label: 'testbox',
        address: '127.0.0.1',
        port: sshd.port,
        user: Platform.environment['USER']!,
        keyId: 'k',
        mosh: true,
      );
      terminal = Terminal()..resize(80, 24);
      before = moshServers(sshd.port);
    });
    tearDown(() async {
      for (final s in sessions) {
        s.close();
      }
      sessions.clear();
      // Closing ends the servers over SSH; give it the time, then make sure.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (moshServers(sshd.port).difference(before).isNotEmpty &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final left = killMoshServersSince(before, sshd.port);
      await sshd.stop();
      expect(left, isEmpty, reason: 'a mosh-server was left running');
    });

    Future<MoshShellSession> start([Host? on]) async {
      final s = await MoshShellSession.start(
        ssh: sshd.connect,
        host: on ?? host,
        terminal: terminal,
        timeout: const Duration(seconds: 5),
      );
      sessions.add(s);
      return s;
    }

    Future<void> showsText(String text) => until(
      () => terminal.buffer.getText().contains(text),
      '"$text" on the screen:\n${terminal.buffer.getText()}',
    );

    /// The output differs from the typed line: `printf 'm%s\n' k` prints
    /// "mk". It works in sh and fish.
    Future<void> runs(String mark) async {
      terminal.textInput("printf '$mark%s\\n' k\r");
      await showsText('${mark}k');
    }

    test('runs commands, and the link goes live', () async {
      final session = await start();
      await runs('first');
      await until(
        () => session.link.value.link == MoshLink.live,
        'a live link',
      );
      await until(() => session.link.value.rtt != null, 'a round trip time');
    });

    test('a resize reaches the shell', () async {
      await start();
      await runs('ready');
      terminal.resize(100, 30);
      terminal.textInput("stty size | sed 's/^/size:/'\r");
      await showsText('size:30 100');
    });

    test('exit ends the session, and the server with it', () async {
      final session = await start();
      await runs('before-exit');
      terminal.textInput('exit\r');
      final end = await session.done.timeout(const Duration(seconds: 10));
      expect(end, (exitCode: null, lost: false));
      await until(
        () => moshServers(sshd.port).difference(before).isEmpty,
        'no server',
      );
    });

    test('close ends the mosh-server on the PC', () async {
      final session = await start();
      await runs('before-close');
      expect(moshServers(sshd.port).difference(before), hasLength(1));
      session.close();
      await until(
        () => moshServers(sshd.port).difference(before).isEmpty,
        'no server',
      );
    });

    test('a session lives through a new local socket', () async {
      final session = await start();
      await runs('old-socket');
      await session.appResumed();
      await runs('new-socket');
    });

    test(
      'UDP goes where SSH went, not to the first address of the name',
      () async {
        // "localhost" is ::1 first here, but sshd and so mosh-server listen
        // on 127.0.0.1 only: SSH falls back to it, UDP must follow.
        final first = (await InternetAddress.lookup('localhost')).first;
        final dir = await Directory.systemTemp.createTemp('shellherd-mosh-');
        addTearDown(() => dir.delete(recursive: true));
        final keys = KeyStore(MemorySecretStore());
        final keyId = await keys.generate();
        await sshd.authorize(await keys.publicLine(keyId));
        final knownHosts = KnownHosts(JsonFile(File('${dir.path}/kh.json')));
        await knownHosts.trust('localhost', sshd.port, sshd.hostKey);
        final connector = SshConnector(
          knownHosts: knownHosts,
          keys: keys,
          askTrust: (_, _) async => false,
          timeout: const Duration(seconds: 5),
        );
        final byName = Host(
          id: 'h2',
          label: 'byname',
          address: 'localhost',
          port: sshd.port,
          user: host.user,
          keyId: keyId,
        );
        final client = await connector.open(byName);
        expect(sshPeerAddress(client), InternetAddress.loopbackIPv4);
        client.close();

        final session = await MoshShellSession.start(
          ssh: () => connector.open(byName),
          host: byName,
          terminal: terminal,
          timeout: const Duration(seconds: 5),
        );
        sessions.add(session);
        await runs('by-name');
        expect(
          first,
          isNot(InternetAddress.loopbackIPv4),
          reason: 'only a real test where the name resolves elsewhere first',
        );
        // The kill needs the trusted key, which goes with the test's files.
        session.close();
        await until(
          () => moshServers(sshd.port).difference(before).isEmpty,
          'no server',
        );
      },
    );

    test('closing an older session leaves the terminal to a newer one', () async {
      final first = await start();
      await runs('first-session');
      await start();
      // The older session ends after the newer one took the terminal, as a
      // reconnect does.
      first.close();
      await runs('second-session');
      terminal.resize(90, 25);
      terminal.textInput("stty size | sed 's/^/size:/'\r");
      await showsText('size:25 90');
    });

    test('a missing mosh-server says so', () async {
      final missing = Host(
        id: host.id,
        label: host.label,
        address: host.address,
        port: host.port,
        user: host.user,
        keyId: host.keyId,
        moshServer: '/nonexistent/mosh-server',
      );
      await expectLater(
        start(missing),
        throwsA(
          isA<MoshServerMissing>().having(
            (e) => e.path,
            'path',
            '/nonexistent/mosh-server',
          ),
        ),
      );
    });
  });
}
