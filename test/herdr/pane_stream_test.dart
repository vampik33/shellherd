import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/herdr_link.dart';
import 'package:shellherd/herdr/pane_stream.dart';
import 'package:shellherd/herdr/ui/ansi_text.dart';
import 'package:xterm/xterm.dart';

import '../support/fake_screens.dart';
import '../support/poll.dart';

const _settle = Duration(milliseconds: 40);

/// What herdr sends as the first frame: synchronized output, a hyperlink
/// reset, a clear and the cells.
const _herdrFrame =
    '\x1b[?2026h\x1b[?25l\x1b]8;;\x1b\\\x1b[2J\x1b[1;1H'
    '\x1b[0;39;49msh-5.3\$ \x1b[0m\x1b[3;1Hlast'
    '\x1b[3;5H\x1b[?25h\x1b[?2026l';

String _plain(String text) =>
    text.replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '');

void main() {
  group('ScreenRecord', () {
    test('reads a frame', () {
      final record = ScreenRecord.parse(
        jsonEncode({
          'type': 'terminal.frame',
          'seq': 3,
          'encoding': 'ansi',
          'width': 80,
          'height': 24,
          'full': true,
          'bytes': base64Encode(utf8.encode('hi')),
        }),
      );
      expect(record, isA<ScreenFrame>());
      final frame = record! as ScreenFrame;
      expect((frame.cols, frame.rows), (80, 24));
      expect(utf8.decode(frame.bytes), 'hi');
    });

    test('reads the end and whether the pane is gone', () {
      final gone = ScreenRecord.parse(
        '{"type":"terminal.closed","reason":"terminal session observe '
        'failed: terminal target w9:p9 not found"}',
      );
      expect((gone! as ScreenClosed).paneGone, isTrue);
      final stop = ScreenRecord.parse(
        '{"type":"terminal.closed","reason":"server stopping"}',
      );
      expect((stop! as ScreenClosed).paneGone, isFalse);
      final silent = ScreenRecord.parse('{"type":"terminal.closed"}');
      expect((silent! as ScreenClosed).paneGone, isFalse);
    });

    test('skips lines that are no record', () {
      expect(ScreenRecord.parse('Welcome to fish'), isNull);
      expect(ScreenRecord.parse('{broken'), isNull);
      expect(ScreenRecord.parse('[1, 2]'), isNull);
      expect(ScreenRecord.parse('{"type":"terminal.future"}'), isNull);
    });

    test('a frame it cannot read is a protocol error', () {
      expect(
        () => ScreenRecord.parse(
          '{"type":"terminal.frame","width":1,"height":1,"bytes":"%%"}',
        ),
        throwsA(isA<HerdrProtocolException>()),
      );
      expect(
        () => ScreenRecord.parse('{"type":"terminal.frame","bytes":""}'),
        throwsA(isA<HerdrProtocolException>()),
      );
    });
  });

  group('screenText', () {
    Terminal terminal(int cols, int rows, String bytes) =>
        Terminal(reflowEnabled: false)
          ..resize(cols, rows)
          ..write(bytes);

    test('draws every cell of every row, without the control sequences', () {
      final text = screenText(terminal(10, 3, _herdrFrame));
      expect(_plain(text).split('\n'), [
        'sh-5.3\$   ',
        '          ',
        'last      ',
      ]);
    });

    test('keeps colours and styles as SGR', () {
      final text = screenText(
        terminal(
          12,
          1,
          '\x1b[1;31mA\x1b[0;38;5;208mB\x1b[0;38;2;1;2;3;44mC'
          '\x1b[0;7;97mD\x1b[0m ',
        ),
      );
      expect(text, startsWith('\x1b[0;1;31mA\x1b[0;38;5;208mB'));
      expect(text, contains('\x1b[0;38;2;1;2;3;44mC'));
      expect(text, contains('\x1b[0;7;97mD\x1b[0m '));
      // parseAnsi reads it back: one line, all cells.
      final line = parseAnsi(text).single;
      expect(line.toPlainText(), 'ABCD        ');
    });

    test('a wide character takes its two cells once', () {
      final text = screenText(terminal(4, 1, '界a'));
      expect(_plain(text), '界a ');
    });

    test('a full frame after a resize replaces the old screen', () {
      final t = terminal(10, 3, _herdrFrame)
        ..resize(6, 2)
        ..write('\x1b[2J\x1b[1;1Hnew');
      expect(_plain(screenText(t)).split('\n'), ['new   ', '      ']);
    });
  });

  group('PaneStream', () {
    late FakeScreens screens;
    late ValueNotifier<int> changes;
    ScreenOpener? opener;
    PaneSize? size;
    late PaneStream stream;

    PaneStream build({
      Duration openTimeout = const Duration(seconds: 5),
      Duration retryDelay = const Duration(milliseconds: 10),
    }) => PaneStream(
      () => opener,
      'w1:p1',
      () => size,
      changes: changes,
      openTimeout: openTimeout,
      retryDelay: retryDelay,
    );

    void change() => changes.value++;

    String? shown() => switch (stream.view.value.text) {
      final text? => _plain(text).trimRight(),
      null => null,
    };

    setUp(() {
      screens = FakeScreens();
      changes = ValueNotifier(0);
      opener = screens.open;
      size = const PaneSize(10, 3);
      stream = build();
    });
    tearDown(() {
      stream.dispose();
      changes.dispose();
    });

    Future<FakeScreenChannel> opened(int n) async {
      await until(() => screens.opened.length >= n, 'observer $n');
      return screens.opened[n - 1];
    }

    test('can observe with a link and a pane size, until unavailable',
        () async {
      expect(stream.canObserve, isTrue);
      size = null;
      expect(stream.canObserve, isFalse);
      size = const PaneSize(10, 3);
      opener = null;
      expect(stream.canObserve, isFalse);
      opener = screens.open;
      change();
      stream.running = true;
      (await opened(1)).end();
      await until(() => stream.unavailable.value, 'unavailable');
      expect(stream.canObserve, isFalse);
    });

    test('does nothing until it should run', () async {
      await Future<void>.delayed(_settle);
      expect(screens.opened, isEmpty);
      expect(stream.view.value.text, isNull);
    });

    test('opens at the pane size and shows the frames', () async {
      stream.running = true;
      final channel = await opened(1);
      expect(channel.paneId, 'w1:p1');
      expect(channel.size, const PaneSize(10, 3));
      channel.frame(_herdrFrame, full: true);
      await until(() => shown()?.endsWith('last') ?? false, 'the screen');
      expect(shown()!.split('\n').first.trimRight(), 'sh-5.3\$');
      channel.frame('\x1b[2;1Hmiddle');
      await until(() => shown()?.contains('middle') ?? false, 'the change');
      expect(stream.unavailable.value, isFalse);
    });

    test('draws frames that come together once, and a same screen never',
        () async {
      var draws = 0;
      stream.view.addListener(() => draws++);
      stream.running = true;
      final channel = await opened(1);
      channel
        ..frame('a')
        ..frame('b')
        ..frame('c');
      await until(() => shown() == 'abc', 'the frames');
      await Future<void>.delayed(_settle);
      expect(draws, 1);
      // Only the cursor moves: the text stays the same.
      channel.frame('\x1b[2;1H');
      await Future<void>.delayed(_settle);
      expect(draws, 1);
    });

    test('lines that are no record are skipped', () async {
      stream.running = true;
      final channel = await opened(1);
      channel.line('fish: Unknown command');
      channel.frame('x');
      await until(() => shown() == 'x', 'the frame');
      expect(stream.unavailable.value, isFalse);
    });

    test('waits for a link and for the size of the pane', () async {
      opener = null;
      size = null;
      stream.dispose();
      stream = build()..running = true;
      await Future<void>.delayed(_settle);
      expect(screens.opened, isEmpty);
      opener = screens.open;
      change();
      await Future<void>.delayed(_settle);
      expect(screens.opened, isEmpty, reason: 'no size yet');
      size = const PaneSize(20, 5);
      change();
      expect((await opened(1)).size, const PaneSize(20, 5));
    });

    test('a new pane size starts a new observer at that size', () async {
      stream.running = true;
      final first = await opened(1);
      first.frame('old');
      await until(() => shown() == 'old', 'the frame');
      change();
      await Future<void>.delayed(_settle);
      expect(screens.opened, hasLength(1), reason: 'same size');
      size = const PaneSize(30, 4);
      change();
      final second = await opened(2);
      expect(first.closed, isTrue);
      expect(second.size, const PaneSize(30, 4));
      expect(shown(), 'old', reason: 'kept until the new frame');
      second.frame('\x1b[2J\x1b[1;1Hnew');
      await until(() => shown() == 'new', 'the new frame');
    });

    test('stops while it should not run, and starts again', () async {
      stream.running = true;
      final first = await opened(1);
      first.frame('one');
      await until(() => shown() == 'one', 'the frame');
      stream.running = false;
      expect(first.closed, isTrue);
      await Future<void>.delayed(_settle);
      expect(screens.opened, hasLength(1));
      expect(shown(), 'one', reason: 'the last screen stays');
      stream.running = true;
      await opened(2);
    });

    test('an observer that ends after frames is started again', () async {
      stream.running = true;
      final first = await opened(1);
      first.frame('one');
      await until(() => shown() == 'one', 'the frame');
      first.fail(const HerdrConnectionClosedException('observe'));
      final second = await opened(2);
      second.frame('two');
      await until(() => shown() == 'two', 'the frame');
      second.end();
      await opened(3);
      expect(stream.unavailable.value, isFalse);
    });

    test('a closed pane ends the stream for good', () async {
      stream.running = true;
      final channel = await opened(1);
      channel.frame('bye');
      await until(() => shown() == 'bye', 'the frame');
      channel.closedRecord('terminal attach ended: terminal t1 not found');
      await until(() => stream.view.value.gone, 'gone');
      expect(shown(), 'bye');
      await Future<void>.delayed(_settle);
      expect(screens.opened, hasLength(1));
    });

    test('a pane that is gone before the first frame is gone', () async {
      stream.running = true;
      (await opened(1)).closedRecord(
        'terminal session observe failed: terminal target w1:p1 not found',
      );
      await until(() => stream.view.value.gone, 'gone');
      expect(stream.unavailable.value, isFalse);
    });

    for (final (what, fail) in <(String, void Function(FakeScreenChannel))>[
      ('exits with an error', (c) => c.fail(StateError('exit 127'))),
      ('exits without a frame', (c) => c.end()),
      ('is closed by herdr', (c) => c.closedRecord('protocol mismatch')),
    ]) {
      test('an observer that $what at once is unavailable', () async {
        stream.running = true;
        fail(await opened(1));
        await until(() => stream.unavailable.value, 'unavailable');
        await Future<void>.delayed(_settle);
        expect(screens.opened, hasLength(1), reason: 'no retry');
        expect(stream.view.value.gone, isFalse);
      });
    }

    test('an open that fails makes it unavailable', () async {
      screens.failOpen = StateError('channel refused');
      stream.running = true;
      await until(() => stream.unavailable.value, 'unavailable');
      expect(screens.opened, isEmpty);
    });

    test('no first frame in time makes it unavailable', () async {
      stream.dispose();
      stream = build(openTimeout: const Duration(milliseconds: 30))
        ..running = true;
      final channel = await opened(1);
      await until(() => stream.unavailable.value, 'unavailable');
      expect(channel.closed, isTrue);
    });

    test('an open that hangs makes it unavailable; a late one closes', () async {
      final hold = screens.holdOpen = Completer<void>();
      stream.dispose();
      stream = build(openTimeout: const Duration(milliseconds: 30))
        ..running = true;
      await until(() => stream.unavailable.value, 'unavailable');
      hold.complete();
      final late = await opened(1);
      await until(() => late.closed, 'the late channel closed');
    });

    test('a new link tries again after it was unavailable', () async {
      stream.running = true;
      (await opened(1)).end();
      await until(() => stream.unavailable.value, 'unavailable');
      expect(stream.whyUnavailable, 'no first frame');
      final next = FakeScreens();
      opener = next.open;
      change();
      expect(stream.unavailable.value, isFalse);
      expect(stream.whyUnavailable, isNull);
      await until(() => next.opened.isNotEmpty, 'an observer on the new link');
    });

    test('a lost link stops the observer; the next link opens one', () async {
      stream.running = true;
      final first = await opened(1);
      first.frame('one');
      await until(() => shown() == 'one', 'the frame');
      opener = null;
      change();
      expect(first.closed, isTrue);
      await Future<void>.delayed(_settle);
      expect(screens.opened, hasLength(1));
      opener = screens.open;
      change();
      await opened(2);
    });

    test('dispose closes the observer', () async {
      stream.running = true;
      final channel = await opened(1);
      stream.dispose();
      expect(channel.closed, isTrue);
      stream = build();
    });
  });

  group('observeCommand', skip: Platform.isLinux ? false : 'needs sh', () {
    late Directory home;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('shellherd-observe-');
      await Directory('${home.path}/.local/bin').create(recursive: true);
    });
    tearDown(() => home.delete(recursive: true));

    /// A fake herdr in ~/.local/bin that runs [body].
    Future<void> fakeHerdr(String body) async {
      final file = File('${home.path}/.local/bin/herdr');
      await file.writeAsString('#!/bin/sh\n$body\n');
      await Process.run('chmod', ['+x', file.path]);
    }

    /// Runs the command as sshd would through the login shell [shell],
    /// with a PATH that has no herdr.
    Future<Process> run(
      String socket,
      String pane,
      PaneSize size, {
      String shell = '/bin/sh',
    }) => Process.start(shell, [
      '-c',
      observeCommand(socket, pane, size),
    ], environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin'});

    test('finds herdr in ~/.local/bin and passes socket, pane and size',
        () async {
      await fakeHerdr(r'printf "%s|" "$HERDR_SOCKET_PATH" "$@"');
      final socket = '${home.path}/it\'s a dir/herdr.sock';
      final process = await run(socket, 'w1:p2', const PaneSize(81, 23));
      final out = await process.stdout.transform(utf8.decoder).join();
      expect(await process.exitCode, 0);
      expect(
        out,
        '$socket|terminal|session|observe|w1:p2|--cols|81|--rows|23|',
      );
    });

    test('without herdr it exits 127 and says why', () async {
      final process = await run('/s.sock', 'w1:p1', const PaneSize(1, 1));
      final err = await process.stderr.transform(utf8.decoder).join();
      expect(await process.exitCode, 127);
      expect(err, contains('herdr is not on the PATH'));
    });

    test('passes on the exit code of herdr', () async {
      await fakeHerdr('echo "protocol mismatch" >&2; exit 3');
      final process = await run('/s.sock', 'w1:p1', const PaneSize(1, 1));
      expect(await process.exitCode, 3);
    });

    test('the end of stdin stops herdr', () async {
      final pidFile = '${home.path}/pid';
      await fakeHerdr('echo \$\$ > $pidFile; echo ready; exec sleep 60');
      final process = await run('/s.sock', 'w1:p1', const PaneSize(1, 1));
      final lines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      final first = StreamIterator(lines);
      expect(await first.moveNext(), isTrue);
      expect(first.current, 'ready');
      final herdrPid = int.parse((await File(pidFile).readAsString()).trim());
      // A failed check must not leave the fake herdr running.
      addTearDown(() => Process.killPid(herdrPid));
      await process.stdin.close();
      expect(
        await process.exitCode.timeout(const Duration(seconds: 5)),
        isNot(0),
      );
      await eventually(
        () async =>
            (await Process.run('kill', ['-0', '$herdrPid'])).exitCode != 0,
        'herdr stopped',
        within: const Duration(seconds: 5),
      );
      await first.cancel();
    });

    for (final shell in ['/bin/sh', '/usr/bin/fish']) {
      test('passes an odd socket path as one word ($shell)',
          skip: File(shell).existsSync() ? false : '$shell is missing',
          () async {
        await fakeHerdr(r'printf "%s|" "$HERDR_SOCKET_PATH" "$@"');
        // No quote or backslash: fish reads those inside single quotes.
        const socket = r'/a dir/$HOME; x/herdr.sock';
        const pane = 'w1:p1';
        final process = await run(
          socket,
          pane,
          const PaneSize(1, 1),
          shell: shell,
        );
        final err = process.stderr.transform(utf8.decoder).join();
        final out = await process.stdout.transform(utf8.decoder).join();
        expect(await process.exitCode, 0, reason: await err);
        expect(out, '$socket|terminal|session|observe|$pane|--cols|1|--rows|1|');
      });
    }

    test('refuses a pane id that is no herdr id', () {
      expect(
        () => observeCommand('/s.sock', "w1:p1'; rm -rf ~", const PaneSize(1, 1)),
        throwsArgumentError,
      );
    });
  });
}
