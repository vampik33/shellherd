/// transcriptCommand run by a real sh, as sshd would run it.
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/transcript/transcript_command.dart';
import 'package:shellherd/herdr/transcript/transcript_stream.dart';
import 'package:shellherd/ssh/ssh_exec.dart';

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
      TranscriptMark? from,
    }) => Process.start(
      shell,
      ['-c', transcriptCommand(id, from: from)],
      environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin', ...env},
      includeParentEnvironment: false,
    );

    /// The lines [process] prints, one at a time.
    StreamIterator<String> lines(Process process) => StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );

    Future<void> expectLines(
      StreamIterator<String> out,
      List<Object> want,
    ) async {
      for (final line in want) {
        expect(await out.moveNext(), isTrue, reason: 'no line $line');
        expect(out.current, line);
      }
    }

    /// A header for a file of [size] bytes read from [start].
    Matcher head(int size, {int start = 0}) => matches(
      RegExp('^${RegExp.escape(transcriptHeader)}$size $start [0-9]+\$'),
    );

    /// The first line [process] prints.
    Future<String> firstLine(Process process) async {
      final out = lines(process);
      expect(await out.moveNext(), isTrue);
      final line = out.current;
      await process.stdin.close();
      await out.cancel();
      return line;
    }

    for (final shell in ['/bin/sh', '/usr/bin/fish']) {
      test(
        'goes on from a mark in the same file ($shell)',
        skip: File(shell).existsSync() ? false : '$shell is missing',
        () async {
          final file = await transcript('{"a":1}\n{"b":2}\n');
          final inode = await inodeOf(file);
          final process = await run(
            _id,
            shell: shell,
            from: (inode: inode, line: 0, offset: 8),
          );
          final out = lines(process);
          // From the last line read, which the reader checks.
          await expectLines(out, [
            '${transcriptHeader}16 0 $inode',
            '{"a":1}',
            '{"b":2}',
          ]);
          file.writeAsStringSync('{"c":3}\n', mode: FileMode.append);
          await expectLines(out, ['{"c":3}']);
          await process.stdin.close();
          await out.cancel();
        },
      );
    }

    test('a mark at the start of a file starts at its offset', () async {
      final file = await transcript('{"a":1}\n{"b":2}\n');
      final inode = await inodeOf(file);
      final process = await run(_id, from: (inode: inode, line: 8, offset: 8));
      final out = lines(process);
      await expectLines(out, ['${transcriptHeader}16 8 $inode', '{"b":2}']);
      await process.stdin.close();
      await out.cancel();
    });

    test('a mark past the end of the file starts over', () async {
      final file = await transcript('{"a":1}\n{"b":2}\n');
      final from = (inode: await inodeOf(file), line: 8, offset: 17);
      final process = await run(_id, from: from);
      final out = lines(process);
      await expectLines(out, [head(16), '{"a":1}', '{"b":2}']);
      await process.stdin.close();
      await out.cancel();
    });

    test('a mark in another file starts over', () async {
      final file = await transcript('{"a":1}\n{"b":2}\n');
      final other = '${int.parse(await inodeOf(file)) + 1}';
      final process = await run(_id, from: (inode: other, line: 8, offset: 16));
      final out = lines(process);
      await expectLines(out, [head(16), '{"a":1}', '{"b":2}']);
      await process.stdin.close();
      await out.cancel();
    });

    test('a mark more than the tail behind starts at the tail', () async {
      final size = transcriptTail + 100;
      final file = await transcript('${'x' * (size - 1)}\n');
      final inode = await inodeOf(file);
      expect(
        await firstLine(
          await run(_id, from: (inode: inode, line: 60, offset: 100)),
        ),
        '$transcriptHeader$size 60 $inode',
        reason: 'grew by exactly the tail: goes on',
      );
      expect(
        await firstLine(
          await run(_id, from: (inode: inode, line: 40, offset: 50)),
        ),
        '$transcriptHeader$size 99 $inode',
        reason: 'grew by more: the tail and the byte before it',
      );
    });

    test('a mark with no file yet waits and reads it from the start', () async {
      await Directory('${home.path}/.claude/projects').create(recursive: true);
      final process = await run(_id, from: (inode: '5', line: 0, offset: 3));
      final out = lines(process);
      await expectLines(out, ['${transcriptHeader}0 0 -']);
      await transcript('{"first":1}\n');
      await expectLines(out, ['{"first":1}']);
      await process.stdin.close();
      await out.cancel();
    });

    test('refuses a mark it cannot pass safely', () {
      for (final from in [
        (inode: '', line: 0, offset: 0),
        (inode: '1;x', line: 0, offset: 0),
        (inode: r'$HOME', line: 0, offset: 0),
        (inode: '1 2', line: 0, offset: 0),
        (inode: '1' * 21, line: 0, offset: 0),
        (inode: '1', line: 0, offset: -1),
        (inode: '1', line: -1, offset: 0),
        (inode: '1', line: -1, offset: 5),
        (inode: '1', line: 6, offset: 5),
      ]) {
        expect(
          () => transcriptCommand(_id, from: from),
          throwsArgumentError,
          reason: '$from',
        );
      }
    });

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
          await expectLines(out, [head(16), '{"a":1}', '{"b":2}']);
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
      await expectLines(out, [head(13), '{"config":1}']);
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
      await expectLines(out, [head(10), '{"new":1}']);
      await process.stdin.close();
      await out.cancel();
    });

    test('a big file starts with its last part', () async {
      final line = '${'y' * 1023}\n';
      final size = transcriptTail + 10 * line.length + 5;
      final file = await transcript(
        '${'z' * 5}${line * (size ~/ line.length)}',
      );
      final process = await run(_id);
      final out = <int>[];
      final read = process.stdout.listen(out.addAll);
      final start = size - transcriptTail - 1;
      final header = utf8.encode(
        '$transcriptHeader$size $start ${await inodeOf(file)}\n',
      );
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

    test('follows the file it opened, though another is renamed over it '
        'before tail starts', () async {
      final file = await transcript('{"a":1}\n');
      final inode = await inodeOf(file);
      final other = File('${home.path}/other.jsonl')
        ..writeAsStringSync('{"replacement":1}\n');
      // A tail that renames the other file over the transcript first.
      final bin = await Directory('${home.path}/bin').create();
      final tail = File('${bin.path}/tail')
        ..writeAsStringSync(
          '#!/bin/sh\n'
          'mv -f -- ${shQuote(other.path)} ${shQuote(file.path)}\n'
          'exec /usr/bin/tail "\$@"\n',
        );
      await Process.run('chmod', ['+x', tail.path]);
      final process = await run(
        _id,
        env: {'PATH': '${bin.path}:/usr/bin:/bin'},
      );
      final out = lines(process);
      await expectLines(out, ['${transcriptHeader}8 0 $inode', '{"a":1}']);
      await eventually(
        () async => await inodeOf(file) != inode,
        'renamed over',
        within: const Duration(seconds: 5),
      );
      // What the replacement gets does not come either.
      file.writeAsStringSync('{"later":1}\n', mode: FileMode.append);
      await process.stdin.close();
      expect(await out.moveNext(), isFalse);
      await process.exitCode.timeout(const Duration(seconds: 5));
    });

    test('its header is of the file it opened, though another is renamed '
        'over it first', () async {
      final file = await transcript('{"a":1}\n');
      final inode = await inodeOf(file);
      final other = File('${home.path}/other.jsonl')
        ..writeAsStringSync('{"replacement, longer":1}\n');
      // A wc that renames the other file over the transcript first.
      final bin = await Directory('${home.path}/bin').create();
      final wc = File('${bin.path}/wc')
        ..writeAsStringSync(
          '#!/bin/sh\n'
          '[ -e ${shQuote(other.path)} ] && '
          'mv -f -- ${shQuote(other.path)} ${shQuote(file.path)}\n'
          'exec /usr/bin/wc "\$@"\n',
        );
      await Process.run('chmod', ['+x', wc.path]);
      final process = await run(
        _id,
        env: {'PATH': '${bin.path}:/usr/bin:/bin'},
      );
      final out = lines(process);
      await expectLines(out, ['${transcriptHeader}8 0 $inode', '{"a":1}']);
      expect(await inodeOf(file), isNot(inode), reason: 'renamed over');
      await process.stdin.close();
      await out.cancel();
    });

    test('ends once another file is renamed over the one it reads', () async {
      final file = await transcript('{"a":1}\n');
      final other = File('${home.path}/other.jsonl')
        ..writeAsStringSync('{"replacement":1}\n');
      final process = await run(_id);
      final out = lines(process);
      await expectLines(out, [head(8), '{"a":1}']);
      other.renameSync(file.path);
      // Stdin stays open: the read ends of itself.
      expect(await process.exitCode.timeout(const Duration(seconds: 8)), 0);
      expect(await out.moveNext(), isFalse);
      expect(await _tailsOf(file.path), isEmpty);
    });

    test(
      'a session whose transcript is not written yet waits for it',
      () async {
        await transcript('{}\n', id: 'another-session');
        final process = await run(_id);
        final out = lines(process);
        await expectLines(out, ['${transcriptHeader}0 0 -']);
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
      await expectLines(out, ['${transcriptHeader}0 0 -']);
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

  group(
    'transcriptRangeCommand',
    skip: Platform.isLinux ? false : 'needs sh',
    () {
      late Directory home;

      setUp(() async {
        home = await Directory.systemTemp.createTemp('shellherd-txr-');
        addTearDown(() => home.delete(recursive: true));
      });

      Future<File> transcript(List<int> bytes, {String id = _id}) async {
        final dir = await Directory('${home.path}/.claude/projects/-home-u-app')
            .create(recursive: true);
        return File('${dir.path}/$id.jsonl')..writeAsBytesSync(bytes);
      }

      /// Runs the command as sshd would through [shell], with [path] first
      /// on PATH; its output as bytes.
      Future<(List<int>, int, String)> run(
        TranscriptRange range, {
        String shell = '/bin/sh',
        String? path,
      }) async {
        final r = await Process.run(
          shell,
          ['-c', transcriptRangeCommand(_id, range)],
          environment: {
            'HOME': home.path,
            'PATH': [?path, '/usr/bin:/bin'].join(':'),
          },
          includeParentEnvironment: false,
          stdoutEncoding: null,
        );
        return (r.stdout as List<int>, r.exitCode, '${r.stderr}');
      }

      final content = utf8.encode('{"a":"é"}\n{"b":"日本"}\n{"c":3}\n');

      for (final shell in ['/bin/sh', '/usr/bin/fish']) {
        test(
          'prints the bytes of the range after its header ($shell)',
          skip: File(shell).existsSync() ? false : '$shell is missing',
          () async {
            final inode = await inodeOf(await transcript(content));
            for (final (from, to) in [(0, content.length), (3, 17), (12, 13)]) {
              final range = (inode: inode, from: from, to: to);
              final (out, code, _) = await run(range, shell: shell);
              expect(code, 0);
              expect(
                utf8.decode(out).split('\n').first,
                '$transcriptHeader${content.length} $from $inode',
              );
              expect(
                transcriptRangeBody(out, range),
                content.sublist(from, to),
                reason: '$from-$to',
              );
            }
          },
        );
      }

      test('a shorter file gives only the header; no file of the inode '
          'exits 65', () async {
        final inode = await inodeOf(await transcript(content));
        final short = (inode: inode, from: 0, to: content.length + 1);
        final (out, code, _) = await run(short);
        expect(code, 0);
        expect(
          () => transcriptRangeBody(out, short),
          throwsA(
            isA<TranscriptRangeFailed>().having(
              (e) => e.changed,
              'changed',
              true,
            ),
          ),
        );
        final (_, gone, err) = await run((
          inode: '${int.parse(inode) + 1}',
          from: 0,
          to: 4,
        ));
        expect(gone, 65);
        expect(err, contains('with inode'));
      });

      test('reads the file of the inode where another of the session is '
          'newer', () async {
        final inode = await inodeOf(await transcript(content));
        final dir = await Directory(
          '${home.path}/.claude/projects/-home-u-other',
        ).create(recursive: true);
        File('${dir.path}/$_id.jsonl')
          ..writeAsStringSync('{"other":1}\n{"other":2}\n{"other":3}\n')
          ..setLastModifiedSync(DateTime.now().add(const Duration(hours: 1)));
        final range = (inode: inode, from: 3, to: 17);
        final (out, code, _) = await run(range);
        expect(code, 0);
        expect(transcriptRangeBody(out, range), content.sublist(3, 17));
      });

      test('reads the bytes of the file it checked, though another is '
          'renamed over it before the read', () async {
        final file = await transcript(content);
        final inode = await inodeOf(file);
        final other = File('${home.path}/other.jsonl')
          ..writeAsStringSync('{"x":"replacement, as long as the file"}\n');
        expect(other.lengthSync(), greaterThan(content.length));
        // A tail that renames the other file over the transcript first.
        final bin = await Directory('${home.path}/bin').create();
        final tail = File('${bin.path}/tail')
          ..writeAsStringSync(
            '#!/bin/sh\n'
            'mv -f -- ${shQuote(other.path)} ${shQuote(file.path)}\n'
            'exec /usr/bin/tail "\$@"\n',
          );
        await Process.run('chmod', ['+x', tail.path]);
        final range = (inode: inode, from: 3, to: 17);
        final (out, code, _) = await run(range, path: bin.path);
        expect(code, 0);
        expect(await inodeOf(file), isNot(inode), reason: 'renamed over');
        expect(transcriptRangeBody(out, range), content.sublist(3, 17));
      });

      test('without a transcript it exits 65, without projects 66', () async {
        final range = (inode: '1', from: 0, to: 4);
        var (_, code, err) = await run(range);
        expect(code, 66);
        expect(err, contains('no Claude Code transcripts in'));
        await transcript(content, id: 'another-session');
        (_, code, err) = await run(range);
        expect(code, 65);
        expect(err, contains('no transcript of session $_id'));
      });

      test('refuses an id or a range it cannot take', () {
        const ok = (inode: '12', from: 0, to: 4);
        expect(() => transcriptRangeCommand('a b', ok), throwsArgumentError);
        for (final range in [
          (inode: '1;x', from: 0, to: 4),
          (inode: '', from: 0, to: 4),
          (inode: '12', from: -1, to: 4),
          (inode: '12', from: 4, to: 4),
          (inode: '12', from: 5, to: 4),
        ]) {
          expect(
            () => transcriptRangeCommand(_id, range),
            throwsArgumentError,
            reason: '$range',
          );
        }
      });
    },
  );

  group('transcriptRangeBody', () {
    const range = (inode: '7', from: 10, to: 14);

    test('skips what startup files print before the header', () {
      final out = utf8.encode(
        'Welcome!\nnoise $transcriptHeader${20} 10 7\nabcd',
      );
      expect(transcriptRangeBody(out, range), utf8.encode('abcd'));
    });

    test('fails without a header, for another file, or bytes missing', () {
      for (final text in [
        'abcd',
        '${transcriptHeader}20 10 8\nabcd',
        '${transcriptHeader}13 10 7\nabcd',
        '${transcriptHeader}20 10 -\nabcd',
        '${transcriptHeader}20 10 7\nabc',
        '${transcriptHeader}20 10 7\nabcde',
        '${transcriptHeader}20 10 7',
      ]) {
        expect(
          () => transcriptRangeBody(utf8.encode(text), range),
          throwsA(isA<TranscriptRangeFailed>()),
          reason: text,
        );
      }
    });
  });
}

/// Whether one of the descriptors in [fds], a `/proc/<pid>/fd`, is [path].
bool _opens(String fds, String path) {
  try {
    return Directory(fds).listSync().any((fd) {
      try {
        return Link(fd.path).targetSync() == path;
      } on FileSystemException {
        return false;
      }
    });
  } on FileSystemException {
    return false;
  }
}

/// The inode of [file], as the command prints it.
Future<String> inodeOf(File file) async => (await Process.run('stat', [
  '-c',
  '%i',
  file.path,
])).stdout.toString().trim();

/// The pids of tail processes that follow [path], by name or open.
Future<List<int>> _tailsOf(String path) async {
  final found = <int>[];
  for (final dir in Directory('/proc').listSync().whereType<Directory>()) {
    final pid = int.tryParse(
      dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty),
    );
    if (pid == null) continue;
    try {
      final args = File('${dir.path}/cmdline').readAsStringSync().split('\x00');
      if (!args.first.endsWith('tail')) continue;
      if (args.contains(path) || _opens('${dir.path}/fd', path)) found.add(pid);
    } on FileSystemException {
      // Gone, or not ours to read.
    }
  }
  return found;
}
