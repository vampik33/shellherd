/// Runs [SshShellSession] against a throwaway sshd on 127.0.0.1 (see
/// test/support/test_sshd.dart), with the login shell of the current user.
/// Skipped when sshd is not installed.
@Tags(['sshd'])
library;

import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/terminal/ssh_shell_session.dart';
import 'package:xterm/xterm.dart';

import '../support/test_sshd.dart';

void main() {
  final skip = TestSshd.binary == null ? 'sshd is not installed' : null;

  late TestSshd sshd;
  late SSHClient client;
  late Terminal terminal;
  late SshShellSession session;

  setUp(() async {
    if (skip != null) return;
    sshd = await TestSshd.start();
    client = await sshd.connect();
    terminal = Terminal(maxLines: 10000);
  });
  tearDown(() async {
    if (skip != null) return;
    client.close();
    await sshd.signalConnections(ProcessSignal.sigcont).catchError((_) {});
    await sshd.stop();
  });

  /// Waits until the screen shows [text]. The command line also shows what
  /// was typed, so the tests type `printf 'a%sc' b` and wait for "abc".
  Future<void> waitFor(Pattern text) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!terminal.buffer.getText().contains(text)) {
      if (DateTime.now().isAfter(deadline)) {
        fail('no "$text" on the screen:\n${terminal.buffer.getText()}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  void type(String line) => terminal.textInput('$line\r');

  group('SshShellSession', skip: skip ?? false, () {
    test('the shell gets a PTY with the size and TERM of the view', () async {
      terminal.resize(100, 30);
      session = await SshShellSession.start(client, terminal);
      type(r'''printf 'p%s:%s:%s\n' t "$TERM" "$(stty size)"''');
      await waitFor('pt:xterm-256color:30 100');
      session.close();
    });

    test('a resize of the view reaches the PTY', () async {
      session = await SshShellSession.start(client, terminal);
      terminal.resize(120, 40);
      type(r'''printf 'r%s:%s\n' s "$(stty size)"''');
      await waitFor('rs:40 120');
      session.close();
    });

    test('UTF-8 goes both ways', () async {
      session = await SshShellSession.start(client, terminal);
      type("printf 'u%s\\n' ─✓ж");
      await waitFor('u─✓ж');
      session.close();
    });

    test(
      'exit ends the session with the exit code and closes the client',
      () async {
        session = await SshShellSession.start(client, terminal);
        type('exit 3');
        final end = await session.done.timeout(const Duration(seconds: 10));
        expect(end, (exitCode: 3, lost: false));
        expect(client.isClosed, isTrue);
        expect(terminal.onOutput, isNull, reason: 'input goes nowhere now');
      },
    );

    test('close() ends the session and the connection', () async {
      session = await SshShellSession.start(client, terminal);
      session.close();
      expect(await session.done, (exitCode: null, lost: false));
      expect(client.isClosed, isTrue);
      terminal.textInput('ignored\r'); // must not throw
    });

    test('a dropped connection ends the session as lost', () async {
      session = await SshShellSession.start(client, terminal);
      // Kills the sshd processes of the connection, as a crash of the PC
      // would; the listener stays.
      await sshd.signalConnections(ProcessSignal.sigkill);
      final end = await session.done.timeout(const Duration(seconds: 10));
      expect(end, (exitCode: null, lost: true));
    });

    test('a link that stalls after the start ends the session as lost', () async {
      session = await SshShellSession.start(
        client,
        terminal,
        pingEvery: const Duration(seconds: 1),
        pingTimeout: const Duration(seconds: 2),
      );
      // The processes stop but the TCP connection stays open, as when the
      // phone moves to another network: only a missing reply shows it.
      await sshd.signalConnections(ProcessSignal.sigstop);
      final started = Stopwatch()..start();
      final end = await session.done.timeout(const Duration(seconds: 10));
      expect(end, (exitCode: null, lost: true));
      expect(started.elapsed, lessThan(const Duration(seconds: 5)));
      expect(client.isClosed, isTrue);
    });

    test('checkLink ends a stalled session without waiting for the timer', () async {
      session = await SshShellSession.start(
        client,
        terminal,
        pingEvery: const Duration(hours: 1),
        pingTimeout: const Duration(seconds: 1),
      );
      await sshd.signalConnections(ProcessSignal.sigstop);
      await session.checkLink();
      expect(await session.done, (exitCode: null, lost: true));
    });

    test('a deadline that runs out while paused does not count', () async {
      session = await SshShellSession.start(
        client,
        terminal,
        pingEvery: const Duration(hours: 1),
        pingTimeout: const Duration(seconds: 1),
      );
      // A ping on its way when the app goes to the background, with no
      // reply until after its deadline, as when Android freezes the app.
      await sshd.signalConnections(ProcessSignal.sigstop);
      final check = session.checkLink();
      session.appPaused();
      await check;
      await sshd.signalConnections(ProcessSignal.sigcont);
      await session.appResumed();
      type("printf 'p%s\\n' aused");
      await waitFor('paused');
      session.close();
      expect(await session.done, (exitCode: null, lost: false));
    });

    test('a live link survives its pings', () async {
      session = await SshShellSession.start(
        client,
        terminal,
        pingEvery: const Duration(milliseconds: 100),
        pingTimeout: const Duration(seconds: 2),
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await session.checkLink();
      type("printf 'l%s\\n' ive");
      await waitFor('live');
      session.close();
      expect(await session.done, (exitCode: null, lost: false));
    });

    test('a stalled connection fails the start after the timeout', () async {
      await sshd.signalConnections(ProcessSignal.sigstop);
      final started = Stopwatch()..start();
      await expectLater(
        SshShellSession.start(
          client,
          terminal,
          timeout: const Duration(milliseconds: 500),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(started.elapsed, lessThan(const Duration(seconds: 3)));
      expect(client.isClosed, isTrue);
    });

    test('start resets the modes that an earlier program left on', () async {
      terminal.write('kept text\r\n');
      terminal.write(
        '\x1b[?1049h' // alternate screen
        '\x1b[?1003h\x1b[?1006h' // mouse reports
        '\x1b[?25l' // hidden cursor
        '\x1b[?1h\x1b=' // application cursor keys and keypad
        '\x1b[?2004h' // bracketed paste
        '\x1b[4h', // insert mode
      );
      expect(terminal.isUsingAltBuffer, isTrue);
      session = await SshShellSession.start(client, terminal);
      expect(terminal.isUsingAltBuffer, isFalse);
      expect(terminal.mouseMode, MouseMode.none);
      expect(terminal.mouseReportMode, MouseReportMode.normal);
      expect(terminal.cursorVisibleMode, isTrue);
      expect(terminal.cursorKeysMode, isFalse);
      expect(terminal.appKeypadMode, isFalse);
      expect(terminal.bracketedPasteMode, isFalse);
      expect(terminal.insertMode, isFalse);
      expect(terminal.buffer.getText(), contains('kept text'));
      session.close();
    });

    test('a later session on the same terminal keeps its input', () async {
      final first = await SshShellSession.start(client, terminal);
      first.close();
      final second = await SshShellSession.start(
        await sshd.connect(),
        terminal,
      );
      first.close(); // again: must not take the terminal from the second
      type("printf 's%s\\n' 2");
      await waitFor('s2');
      second.close();
    });
  });
}
