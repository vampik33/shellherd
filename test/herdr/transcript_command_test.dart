/// transcriptCommand run by a real sh, as sshd would run it.
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/transcript/transcript_command.dart';
import 'package:shellherd/herdr/transcript/transcript_stream.dart';

import '../support/poll.dart';

const _id = '0d6c1f3e-1b2a-4c5d-8e9f-0a1b2c3d4e5f';

void main() {
  group('transcriptCommand', skip: Platform.isLinux ? false : 'needs sh', () {
    late Directory home;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('shellherd-tx-');
      addTearDown(() => home.delete(recursive: true));
    });

    /// A transcript of session [id] in [project] under [config], by
    /// default ~/.claude.
    Future<File> transcript(
      String text, {
      String project = '-home-u-app',
      String? config,
      String id = _id,
    }) async {
      final dir = await Directory(
        '${config ?? '${home.path}/.claude'}/projects/$project',
      ).create(recursive: true);
      return File('${dir.path}/$id.jsonl')..writeAsStringSync(text);
    }

    /// Runs the command as sshd would through the login shell [shell], with
    /// only HOME and PATH and [env] set.
    Future<Process> run(
      String id, {
      String shell = '/bin/sh',
      Map<String, String> env = const {},
    }) => Process.start(
      shell,
      ['-c', transcriptCommand(id)],
      environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin', ...env},
      includeParentEnvironment: false,
    );

    /// The lines [process] prints, one at a time.
    StreamIterator<String> lines(Process process) => StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );

    Future<void> expectLines(
      StreamIterator<String> out,
      List<String> want,
    ) async {
      for (final line in want) {
        expect(await out.moveNext(), isTrue, reason: 'no line $line');
        expect(out.current, line);
      }
    }

    for (final shell in ['/bin/sh', '/usr/bin/fish']) {
      test(
        'prints the size, the file, then each line added ($shell)',
        skip: File(shell).existsSync() ? false : '$shell is missing',
        () async {
          // An odd project directory: spaces, $ and ; stay as they are.
          final file = await transcript(
            '{"a":1}\n{"b":2}\n',
            project: r'-home-a b$HOME; x',
          );
          final process = await run(_id, shell: shell);
          final out = lines(process);
          await expectLines(out, [
            '${transcriptHeader}16',
            '{"a":1}',
            '{"b":2}',
          ]);
          file.writeAsStringSync('{"c":3}\n', mode: FileMode.append);
          await expectLines(out, ['{"c":3}']);
          await process.stdin.close();
          expect(
            await process.exitCode.timeout(const Duration(seconds: 5)),
            isNot(0),
          );
          await out.cancel();
        },
      );
    }

    test('CLAUDE_CONFIG_DIR is where Claude Code keeps it then', () async {
      await transcript('{"home":1}\n');
      final config = '${home.path}/other config';
      await transcript('{"config":1}\n', config: config);
      final process = await run(_id, env: {'CLAUDE_CONFIG_DIR': config});
      final out = lines(process);
      await expectLines(out, ['${transcriptHeader}13', '{"config":1}']);
      await process.stdin.close();
      await out.cancel();
    });

    test('of two transcripts of one session, the newest', () async {
      final old = await transcript('{"old":1}\n', project: 'a');
      await old.setLastModified(
        DateTime.now().subtract(const Duration(hours: 1)),
      );
      await transcript('{"new":1}\n', project: 'b');
      final process = await run(_id);
      final out = lines(process);
      await expectLines(out, ['${transcriptHeader}10', '{"new":1}']);
      await process.stdin.close();
      await out.cancel();
    });

    test('a big file starts with its last part', () async {
      final line = '${'y' * 1023}\n';
      final size = transcriptTail + 10 * line.length + 5;
      await transcript('${'z' * 5}${line * (size ~/ line.length)}');
      final process = await run(_id);
      final out = <int>[];
      final read = process.stdout.listen(out.addAll);
      final header = utf8.encode('$transcriptHeader$size\n');
      await until(
        () => out.length >= header.length + transcriptTail + 1,
        'the tail',
      );
      expect(utf8.decode(out.sublist(0, header.length)), utf8.decode(header));
      // One byte more than the tail: the reader drops the line it is in.
      expect(out.length, header.length + transcriptTail + 1);
      await process.stdin.close();
      await process.exitCode.timeout(const Duration(seconds: 5));
      await read.cancel();
    });

    test('the end of stdin stops tail', () async {
      final file = await transcript('');
      final process = await run(_id);
      final out = lines(process);
      expect(await out.moveNext(), isTrue);
      expect(await _tailsOf(file.path), isNotEmpty);
      await process.stdin.close();
      await process.exitCode.timeout(const Duration(seconds: 5));
      await eventually(
        () async => (await _tailsOf(file.path)).isEmpty,
        'tail stopped',
        within: const Duration(seconds: 5),
      );
      await out.cancel();
    });

    test(
      'a session whose transcript is not written yet waits for it',
      () async {
        await transcript('{}\n', id: 'another-session');
        final process = await run(_id);
        final out = lines(process);
        await expectLines(out, ['${transcriptHeader}0']);
        await transcript('{"first":1}\n', project: 'new');
        await expectLines(out, ['{"first":1}']);
        await process.stdin.close();
        await process.exitCode.timeout(const Duration(seconds: 5));
        await out.cancel();
      },
    );

    test('the end of stdin stops the wait for a transcript', () async {
      await Directory('${home.path}/.claude/projects').create(recursive: true);
      final process = await run(_id);
      final out = lines(process);
      await expectLines(out, ['${transcriptHeader}0']);
      await process.stdin.close();
      expect(
        await process.exitCode.timeout(const Duration(seconds: 5)),
        isNot(0),
      );
      await out.cancel();
    });

    test('without the projects directory it exits 66 and says why', () async {
      final process = await run(_id);
      final err = process.stderr.transform(utf8.decoder).join();
      await process.stdout.drain<void>();
      expect(await process.exitCode, 66);
      expect(await err, contains('no Claude Code transcripts in'));
    });

    test('refuses an id it cannot pass safely', () {
      for (final id in [
        '',
        '../x',
        'a b',
        "it's",
        r'back\slash',
        r'$HOME',
        'a*',
        'x' * 129,
      ]) {
        expect(() => transcriptCommand(id), throwsArgumentError, reason: id);
      }
    });
  });
}

/// The pids of tail processes that follow [path].
Future<List<int>> _tailsOf(String path) async {
  final found = <int>[];
  for (final dir in Directory('/proc').listSync().whereType<Directory>()) {
    final pid = int.tryParse(
      dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
    );
    if (pid == null) continue;
    try {
      final args = File('${dir.path}/cmdline').readAsStringSync().split('\x00');
      if (args.first.endsWith('tail') && args.contains(path)) found.add(pid);
    } on FileSystemException {
      // Gone, or not ours to read.
    }
  }
  return found;
}
