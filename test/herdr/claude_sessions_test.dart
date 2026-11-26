/// The Claude Code session lookup for the Herdr app: the remote command
/// run by a local `sh`, its parser, and [ClaudeSessions] on the real clock.
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/transcript/claude_sessions.dart';

import '../support/poll.dart';

const _id1 = '0d6c1f3e-1b2a-4c5d-8e9f-0a1b2c3d4e5f';
const _id2 = '8215e075-8c72-44b7-85df-f7793bc23d03';
const _id3 = '142989e8-15e1-4adb-9046-7d45cb8b3666';

/// Long enough for a lookup that should not happen to show.
const _settle = Duration(milliseconds: 60);

String _file(int pid, String session) =>
    jsonEncode({'pid': pid, 'sessionId': session, 'kind': 'interactive'});

String _line(int pid, String json) => '$claudeSessionMarker$pid $json';

void main() {
  group('claudeSessionsCommand', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('claude-sessions'));
    tearDown(() => dir.deleteSync(recursive: true));

    void session(String configDir, int pid, String body) {
      File('$configDir/sessions/$pid.json')
        ..createSync(recursive: true)
        ..writeAsStringSync(body);
    }

    Future<Map<int, String>> run(
      List<int> pids,
      Map<String, String> environment,
    ) async {
      final r = await Process.run('sh', [
        '-c',
        claudeSessionsCommand(pids),
      ], environment: environment);
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return parseClaudeSessions(r.stdout as String, pids);
    }

    test('reads the session of each pid that has a file', () async {
      final config = '${dir.path}/config';
      session(config, 101, _file(101, _id1));
      // Pretty-printed: its newlines are dropped.
      session(
        config,
        102,
        const JsonEncoder.withIndent('  ').convert({
          'pid': 102,
          'sessionId': _id2,
          'note': 'a "quoted" \\ line\nwith a newline',
        }),
      );
      // A file left by an earlier process with the same pid.
      session(config, 104, _file(999, _id3));
      session(config, 105, _file(105, "x'; touch ${dir.path}/pwned; '"));
      session(config, 106, 'not json');
      session(config, 107, '[107]');
      final found = await run(
        [101, 102, 103, 104, 105, 106, 107],
        {'CLAUDE_CONFIG_DIR': config},
      );
      expect(found, {101: _id1, 102: _id2});
      expect(File('${dir.path}/pwned').existsSync(), isFalse);
    });

    test('without CLAUDE_CONFIG_DIR it reads ~/.claude', () async {
      session('${dir.path}/.claude', 7, _file(7, _id1));
      final found = await run(
        [7],
        {'HOME': dir.path, 'PATH': Platform.environment['PATH']!},
      );
      expect(found, {7: _id1});
    });

    test('takes only process ids', () {
      expect(() => claudeSessionsCommand([]), throwsArgumentError);
      expect(() => claudeSessionsCommand([1, 0]), throwsArgumentError);
      expect(() => claudeSessionsCommand([-3]), throwsArgumentError);
    });
  });

  group('parseClaudeSessions', () {
    test('takes asked pids only, and text before the marker', () {
      final out = [
        'Welcome to the box',
        'motd ${_line(5, _file(5, _id1))}',
        _line(6, _file(6, _id2)),
        _line(8, _file(8, _id3)),
        '${claudeSessionMarker}9',
        '${claudeSessionMarker}x {}',
        _line(10, '{"pid":10,"sessionId":7}'),
        _line(11, '{"pid":"11","sessionId":"$_id1"}'),
      ].join('\n');
      expect(parseClaudeSessions(out, [5, 6, 9, 10, 11]), {5: _id1, 6: _id2});
    });

    test('random output: exactly the valid entries of asked pids', () {
      final random = Random(7);
      const ids = [_id1, _id2, _id3, 'abc_DEF-1'];
      for (var round = 0; round < 300; round++) {
        final expected = <int, String>{};
        final asked = <int>{};
        final lines = <String>[];
        final used = <int>{};
        for (var i = random.nextInt(8); i > 0; i--) {
          final pid = 1 + random.nextInt(50);
          if (!used.add(pid)) continue;
          final ask = random.nextBool();
          if (ask) asked.add(pid);
          final id = ids[random.nextInt(ids.length)];
          final noise = random.nextInt(4) == 0 ? 'banner ' : '';
          switch (random.nextInt(4)) {
            case 0:
              lines.add('$noise${_line(pid, _file(pid, id))}');
              if (ask) expected[pid] = id;
            case 1:
              lines.add(_line(pid, _file(pid + 1, id)));
            case 2:
              lines.add(_line(pid, _file(pid, '$id/../x')));
            default:
              lines.add('just text $pid');
          }
        }
        lines.shuffle(random);
        expect(
          parseClaudeSessions(lines.join('\n'), asked),
          expected,
          reason: lines.join('\n'),
        );
      }
    });
  });

  group('ClaudeSessions', () {
    late List<List<int>> asked;
    late Map<int, String> files;
    late int changes;
    Object? failWith;
    Completer<void>? hold;
    late ClaudeSessions sessions;

    Future<Map<int, String>> lookup(List<int> pids) async {
      asked.add(pids);
      await hold?.future;
      if (failWith case final e?) throw e;
      return {for (final p in pids) p: ?files[p]};
    }

    ClaudeSessions start({Duration refresh = const Duration(minutes: 1)}) =>
        sessions = ClaudeSessions(
          lookup,
          onChange: () => changes++,
          refreshEvery: refresh,
        );

    setUp(() {
      asked = [];
      files = {1: _id1, 2: _id2};
      changes = 0;
      failWith = null;
      hold = null;
    });
    tearDown(() => sessions.close());

    test('looks up new pids once; drops pids no longer wanted', () async {
      start();
      sessions.want({2, 1});
      await until(() => changes == 1, 'the first lookup');
      expect(asked, [
        [1, 2],
      ]);
      expect(sessions.known, {1: _id1, 2: _id2});

      sessions.want({1, 2});
      await Future<void>.delayed(_settle);
      expect(asked, hasLength(1), reason: 'nothing new');

      sessions.want({1, 2, 3});
      await until(() => asked.length == 2, 'the new pid');
      expect(asked.last, [3]);
      await Future<void>.delayed(_settle);
      expect(changes, 1, reason: 'pid 3 has no session');

      sessions.want({1});
      expect(sessions.known, {1: _id1});
      await Future<void>.delayed(_settle);
      expect(asked, hasLength(2));
    });

    test('a refresh finds a new session in the same process', () async {
      start(refresh: const Duration(milliseconds: 40));
      sessions.want({1});
      await until(() => changes == 1, 'the first lookup');
      // /clear
      files[1] = _id3;
      await until(() => changes == 2, 'the new session');
      expect(sessions.known, {1: _id3});
      final lookups = asked.length;
      await until(() => asked.length > lookups + 1, 'more refreshes');
      expect(changes, 2, reason: 'the same session is no change');
      expect(
        asked.every((pids) => pids.length == 1 && pids.first == 1),
        isTrue,
      );
    });

    test('a session file that goes away drops the session', () async {
      start(refresh: const Duration(milliseconds: 40));
      sessions.want({1});
      await until(() => changes == 1, 'the first lookup');
      files.remove(1);
      await until(() => changes == 2, 'the refresh');
      expect(sessions.known, isEmpty);
    });

    test('a failed lookup keeps what was known and tries again', () async {
      start(refresh: const Duration(milliseconds: 40));
      sessions.want({1});
      await until(() => changes == 1, 'the first lookup');
      failWith = StateError('link stalled');
      files[1] = _id3;
      final lookups = asked.length;
      await until(() => asked.length >= lookups + 2, 'failed refreshes');
      expect(sessions.known, {1: _id1});
      failWith = null;
      await until(() => changes == 2, 'a refresh that works');
      expect(sessions.known, {1: _id3});
    });

    test('a pid wanted during a lookup is looked up after it', () async {
      start();
      final gate = hold = Completer();
      sessions.want({1});
      await until(() => asked.length == 1, 'the first lookup');
      sessions.want({1, 2});
      await Future<void>.delayed(_settle);
      expect(asked, hasLength(1), reason: 'one lookup at a time');
      hold = null;
      gate.complete();
      await until(() => sessions.known.length == 2, 'both sessions');
      expect(asked, [
        [1],
        [2],
      ]);
    });

    test('a pid dropped during its lookup does not come back', () async {
      start();
      final gate = hold = Completer();
      sessions.want({1, 2});
      await until(() => asked.length == 1, 'the lookup');
      sessions.want({1});
      hold = null;
      gate.complete();
      await until(() => changes == 1, 'the lookup ended');
      expect(sessions.known, {1: _id1});
    });

    test('after close nothing is looked up or reported', () async {
      start(refresh: const Duration(milliseconds: 20));
      final gate = hold = Completer();
      sessions.want({1});
      await until(() => asked.length == 1, 'the lookup');
      sessions.close();
      hold = null;
      gate.complete();
      await Future<void>.delayed(_settle);
      expect(changes, 0);
      expect(asked, hasLength(1));
      sessions.want({5});
      await Future<void>.delayed(_settle);
      expect(asked, hasLength(1));
    });
  });
}
