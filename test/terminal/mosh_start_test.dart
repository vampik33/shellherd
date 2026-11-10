/// The mosh-server start command, run by a real `sh` against a fake
/// mosh-server, and the reading of what it prints.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/terminal/mosh_shell_session.dart';

const _key = 'AAECAwQFBgcICQoLDA0ODw';

String _output({int pid = 4242}) =>
    '\nMOSH CONNECT 60003 $_key\n\n'
    'mosh-server (mosh 1.4.0)\n'
    '[mosh-server detached, pid = $pid]\n';

void main() {
  group('moshStartCommand', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('shellherd mosh ');
    });
    tearDown(() => dir.delete(recursive: true));

    /// A fake mosh-server at [name] in [dir] that prints its arguments and
    /// environment.
    Future<String> fakeServer(String name) async {
      final file = File('${dir.path}/$name');
      await file.writeAsString(
        '#!/bin/sh\n'
        r'printf "args:%s|" "$@"; echo; echo "tmout:$MOSH_SERVER_NETWORK_TMOUT"; '
        r'echo "id:$SHELLHERD_MOSH_ID"'
        '\necho oops >&2\n',
      );
      await Process.run('chmod', ['+x', file.path]);
      return file.path;
    }

    Future<ProcessResult> run(String moshServer, {String? home}) => Process.run(
      'sh',
      ['-c', moshStartCommand(moshServer, 'the-id')],
      environment: {'HOME': ?home},
    );

    test('passes the options, the timeout and the id', () async {
      final r = await run(await fakeServer('mosh-server'));
      expect(r.exitCode, 0);
      final out = r.stdout as String;
      expect(out, contains('id:the-id\n'));
      expect(out, contains('args:new|args:-s|args:-c|args:256|'));
      expect(out, contains('args:-l|args:LANG=C.UTF-8|'));
      expect(out, contains('tmout:86400'));
      expect(out, contains('oops'), reason: 'stderr comes along');
    });

    test("a path with spaces and quotes stays one word", () async {
      final r = await run(await fakeServer("my 'odd' mosh"));
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(r.stdout, contains('args:new|'));
    });

    test('~/ is the home directory', () async {
      await fakeServer('mosh-server');
      final r = await run('~/mosh-server', home: dir.path);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      expect(r.stdout, contains('args:new|'));
    });

    test('a missing server exits with 127', () async {
      final r = await run('${dir.path}/nothing-here');
      expect(r.exitCode, 127);
    });
  });

  group('parseMoshStart', () {
    test('reads port, key and pid', () {
      final start = parseMoshStart(
        'Welcome from a startup file!\n${_output()}',
        path: 'mosh-server',
      );
      expect(start.port, 60003);
      expect(start.key.printable, _key);
      expect(start.pid, 4242);
    });

    test('exit 127 without a connect line: no mosh-server', () {
      expect(
        () => parseMoshStart(
          'sh: 1: exec: mosh-server: not found\n',
          exitCode: 127,
          path: 'mosh-server',
        ),
        throwsA(
          isA<MoshServerMissing>().having((e) => e.path, 'path', 'mosh-server'),
        ),
      );
    });

    test('another failure keeps the last lines of the output', () {
      final lines = [for (var i = 1; i <= 8; i++) 'line $i'].join('\n');
      expect(
        () => parseMoshStart(
          '\n$lines\n',
          exitCode: 1,
          path: 'mosh-server',
        ),
        throwsA(
          isA<MoshStartFailed>().having(
            (e) => e.output,
            'output',
            'line 4\nline 5\nline 6\nline 7\nline 8',
          ),
        ),
      );
    });
  });

  group('parseMoshStart, a bad key', () {
    test('does not show the key line', () {
      expect(
        () => parseMoshStart(
          'MOSH CONNECT 60001 AAECAwQFBgcICQoLDA0ODx\nsomething else\n',
          path: 'mosh-server',
        ),
        throwsA(
          isA<MoshStartFailed>().having((e) => e.output, 'output', 'something else'),
        ),
      );
    });
  });

  group('moshKillCommand', () {
    /// A process like a mosh-server started with [id].
    Future<Process> serverWith(String id) => Process.start(
      'sleep',
      ['30'],
      environment: {'SHELLHERD_MOSH_ID': id},
    );

    Future<bool> alive(Process p) async {
      final exited = await p.exitCode
          .then((_) => true)
          .timeout(const Duration(milliseconds: 300), onTimeout: () => false);
      return !exited;
    }

    test('ends the process of its own id', () async {
      final p = await serverWith('mine');
      await Process.run('sh', ['-c', moshKillCommand(p.pid, 'mine')]);
      expect(await alive(p), isFalse);
    });

    test('leaves a process that took the pid of another session', () async {
      final p = await serverWith('another-session');
      addTearDown(p.kill);
      await Process.run('sh', ['-c', moshKillCommand(p.pid, 'mine')]);
      expect(await alive(p), isTrue);
    });

    test('a pid with no process does nothing', () async {
      final r = await Process.run('sh', ['-c', moshKillCommand(999999999, 'x')]);
      expect(r.stderr, isEmpty);
    });
  });
}
