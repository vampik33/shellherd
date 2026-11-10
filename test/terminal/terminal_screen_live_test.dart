/// Runs [TerminalScreen] with a real [SshConnector] against a throwaway sshd
/// on 127.0.0.1 (see test/support/test_sshd.dart). Skipped when sshd is not
/// installed.
@Tags(['sshd'])
// A hang must fail fast, not after the default 10 minutes.
@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/ssh/host.dart';
import 'package:shellherd/ssh/json_file.dart';
import 'package:shellherd/ssh/key_store.dart';
import 'package:shellherd/ssh/known_hosts.dart';
import 'package:shellherd/ssh/ssh_connector.dart';
import 'package:shellherd/terminal/terminal_screen.dart';
import 'package:shellherd/ui/host_key_dialog.dart';
import 'package:xterm/xterm.dart';

import '../support/live_widgets.dart';
import '../support/memory_secret_store.dart';
import '../support/mosh_servers.dart';
import '../support/test_sshd.dart';

void main() {
  // Real sockets and files need the real clock, not the fake one of
  // testWidgets.
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  final skip = TestSshd.binary == null ? 'sshd is not installed' : null;

  late Directory dir;
  late TestSshd sshd;
  late KnownHosts knownHosts;
  late SshConnector connector;
  late Host host;
  late int prompts;
  final navigator = GlobalKey<NavigatorState>();

  setUp(() async {
    if (skip != null) return;
    dir = await Directory.systemTemp.createTemp('shellherd-term-');
    sshd = await TestSshd.start();
    final keys = KeyStore(MemorySecretStore());
    final keyId = await keys.generate();
    await sshd.authorize(await keys.publicLine(keyId));
    knownHosts = KnownHosts(JsonFile(File('${dir.path}/known_hosts.json')));
    prompts = 0;
    connector = SshConnector(
      knownHosts: knownHosts,
      keys: keys,
      askTrust: (host, key) {
        prompts++;
        return showHostKeyDialog(navigator.currentContext!, host, key);
      },
      timeout: const Duration(seconds: 5),
    );
    host = Host(
      id: 'h1',
      label: 'testbox',
      address: '127.0.0.1',
      port: sshd.port,
      user: Platform.environment['USER']!,
      keyId: keyId,
    );
  });
  tearDown(() async {
    if (skip != null) return;
    await sshd.stop();
    await dir.delete(recursive: true);
  });

  Terminal terminal(WidgetTester tester) =>
      tester.widget<TerminalView>(find.byType(TerminalView)).terminal;

  Future<void> showsText(WidgetTester tester, String text) => until(
    tester,
    () => terminal(tester).buffer.getText().contains(text),
    '"$text" on the screen:\n${terminal(tester).buffer.getText()}',
  );

  /// The command line shows what was typed, so the output has to differ:
  /// `printf 'm%s\n' k` prints "mk".
  Future<void> runsCommands(WidgetTester tester, String mark) async {
    terminal(tester).textInput("printf '$mark%s\\n' k\r");
    await showsText(tester, '${mark}k');
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    bool mosh = false,
    Host? on,
  }) => tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: TerminalScreen(host: on ?? host, connector: connector, mosh: mosh),
    ),
  );

  /// Disposes the screen, which closes its connection.
  Future<void> closeScreen(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  Finder chip(String label) => find.widgetWithText(Chip, label);

  group('TerminalScreen', skip: skip ?? false, () {
    testWidgets('first use asks about the key, then runs a shell', (
      tester,
    ) async {
      await pumpScreen(tester);
      expect(chip('connecting'), findsOneWidget);
      await untilFound(tester, find.text('Trust'));
      expect(
        find.textContaining(sshd.hostKey.fingerprint),
        findsOneWidget,
        reason: 'the dialog shows the fingerprint',
      );
      await tester.tap(find.text('Trust'));
      await untilFound(tester, chip('ssh'));
      await runsCommands(tester, 'a');
      expect(await knownHosts.lookup('127.0.0.1', sshd.port), sshd.hostKey);
      await closeScreen(tester);
    });

    testWidgets('ctrl on the key bar interrupts a command', (tester) async {
      await knownHosts.trust('127.0.0.1', sshd.port, sshd.hostKey);
      await pumpScreen(tester);
      await untilFound(tester, chip('ssh'));
      await runsCommands(tester, 'b'); // the shell reads input now
      terminal(tester).textInput('sleep 60\r');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await tester.tap(find.text('ctrl'));
      await tester.pump();
      terminal(tester).textInput('c');
      // Without the interrupt the shell waits 60 s, and this fails at 10 s.
      await runsCommands(tester, 'c');
      await closeScreen(tester);
    });

    testWidgets('exit shows the exit code; reconnect opens a new shell', (
      tester,
    ) async {
      await knownHosts.trust('127.0.0.1', sshd.port, sshd.hostKey);
      await pumpScreen(tester);
      await untilFound(tester, chip('ssh'));
      terminal(tester).textInput('exit 4\r');
      await untilFound(tester, find.text('Session ended (exit 4).'));
      expect(chip('closed'), findsOneWidget);

      await tester.tap(find.text('Reconnect'));
      await untilFound(tester, chip('ssh'));
      await runsCommands(tester, 'd');
      expect(prompts, 0, reason: 'a known key does not ask');
      await closeScreen(tester);
    });

    testWidgets('a dropped connection says so; reconnect resets the modes', (
      tester,
    ) async {
      await knownHosts.trust('127.0.0.1', sshd.port, sshd.hostKey);
      await pumpScreen(tester);
      await untilFound(tester, chip('ssh'));
      // A full-screen program turns on modes, then the connection drops.
      await runsCommands(tester, 'f'); // the shell reads input now
      terminal(tester).textInput(
        // The shell turns some modes off after a command, so the command
        // keeps running, as vim would. The external printf writes at once;
        // fish holds the output of its builtin until the line ends. \133
        // is "[": fish adds a closing "]" to a typed "[".
        r"command printf '\033\133?1049h\033\133?1003h\033\133?25l\033\133?1h'; sleep 60"
        '\r',
      );
      await until(
        tester,
        () =>
            terminal(tester).isUsingAltBuffer &&
            terminal(tester).mouseMode != MouseMode.none &&
            !terminal(tester).cursorVisibleMode,
        'full-screen modes',
      );
      await sshd.signalConnections(ProcessSignal.sigkill);
      await untilFound(tester, find.text('Connection lost.'));

      await tester.tap(find.text('Reconnect'));
      await untilFound(tester, chip('ssh'));
      final t = terminal(tester);
      expect(t.isUsingAltBuffer, isFalse);
      expect(t.mouseMode, MouseMode.none);
      expect(t.cursorVisibleMode, isTrue);
      expect(t.cursorKeysMode, isFalse);
      await runsCommands(tester, 'e');
      await closeScreen(tester);
    });

    testWidgets('a declined key stops; retry asks again', (tester) async {
      await pumpScreen(tester);
      await untilFound(tester, find.text('Cancel'));
      await tester.tap(find.text('Cancel'));
      await untilFound(tester, find.text('The host key was not trusted.'));
      await tester.tap(find.text('Retry'));
      await untilFound(tester, find.text('Trust'));
      await tester.tap(find.text('Trust'));
      await untilFound(tester, chip('ssh'));
      expect(prompts, 2);
      await closeScreen(tester);
    });

    testWidgets('a changed key shows both keys and offers no retry', (
      tester,
    ) async {
      const old = HostKey('ssh-ed25519', 'SHA256:not-this-server');
      await knownHosts.trust('127.0.0.1', sshd.port, old);
      await pumpScreen(tester);
      await until(
        tester,
        () => find
            .text('The host key of 127.0.0.1 changed.')
            .evaluate()
            .isNotEmpty,
        'changed banner',
      );
      expect(find.textContaining(old.fingerprint), findsOneWidget);
      expect(find.textContaining(sshd.hostKey.fingerprint), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(prompts, 0);
      await closeScreen(tester);
    });
  });

  group(
    'TerminalScreen over mosh',
    skip:
        skip ??
        (Process.runSync('sh', ['-c', 'command -v mosh-server']).exitCode != 0
            ? 'mosh-server is not installed'
            : false),
    () {
      late Set<int> before;
      setUp(() => before = moshServers());
      tearDown(() => killMoshServersSince(before));

      Finder chipStarting(String prefix) => find.byWidgetPredicate(
        (w) =>
            w is Chip && w.label is Text && (w.label as Text).data!.startsWith(prefix),
      );

      testWidgets('runs a shell, shows the round trip, and leaving ends '
          'mosh-server', (tester) async {
        await knownHosts.trust('127.0.0.1', sshd.port, sshd.hostKey);
        await pumpScreen(tester, mosh: true);
        await untilFound(tester, chipStarting('mosh'));
        await runsCommands(tester, 'm');
        await untilFound(tester, chipStarting('mosh · '));
        expect(moshServers().difference(before), hasLength(1));
        await closeScreen(tester);
        await until(
          tester,
          () => moshServers().difference(before).isEmpty,
          'mosh-server to end',
        );
      });

      testWidgets('exit ends the session; reconnect starts a new one', (
        tester,
      ) async {
        await knownHosts.trust('127.0.0.1', sshd.port, sshd.hostKey);
        await pumpScreen(tester, mosh: true);
        await untilFound(tester, chipStarting('mosh'));
        await runsCommands(tester, 'n');
        terminal(tester).textInput('exit\r');
        await untilFound(tester, find.text('Session ended.'));
        expect(chip('closed'), findsOneWidget);
        await tester.tap(find.text('Reconnect'));
        await untilFound(tester, chipStarting('mosh'));
        await runsCommands(tester, 'o');
        await closeScreen(tester);
        await until(
          tester,
          () => moshServers().difference(before).isEmpty,
          'mosh-server to end',
        );
      });

      testWidgets('a missing mosh-server says so', (tester) async {
        await knownHosts.trust('127.0.0.1', sshd.port, sshd.hostKey);
        await pumpScreen(
          tester,
          mosh: true,
          on: Host(
            id: host.id,
            label: host.label,
            address: host.address,
            port: host.port,
            user: host.user,
            keyId: host.keyId,
            moshServer: '/nonexistent/mosh-server',
          ),
        );
        await untilFound(
          tester,
          find.text(
            'mosh-server is not installed on testbox, or not at '
            '"/nonexistent/mosh-server".',
          ),
        );
        expect(find.text('Retry'), findsOneWidget);
        await closeScreen(tester);
      });
    },
  );
}
