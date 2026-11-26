/// Reads the transcript of a Claude Code session that a real herdr
/// reports, over a real SSH connection to a throwaway sshd on 127.0.0.1,
/// against a throwaway named herdr session. The transcripts live in a
/// throwaway CLAUDE_CONFIG_DIR, never in the user's ~/.claude. Skipped when `herdr` or `sshd` is missing.
/// Run alone with: flutter test test/herdr/transcript_live_test.dart
@Tags(['herdr', 'sshd'])
@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/herdr_cache.dart';
import 'package:shellherd/herdr/herdr_connection.dart';
import 'package:shellherd/herdr/herdr_link.dart';
import 'package:shellherd/herdr/transcript/chat_items.dart';
import 'package:shellherd/herdr/transcript/claude_transcript.dart';
import 'package:shellherd/herdr/transcript/transcript_command.dart';
import 'package:shellherd/herdr/transcript/transcript_stream.dart';

import '../support/fake_transcripts.dart';
import '../support/herdr_test_session.dart';
import '../support/poll.dart';
import '../support/test_sshd.dart';

Future<void> main() async {
  final skip = !await HerdrTestSession.herdrAvailable()
      ? 'herdr is not on PATH'
      : TestSshd.binary == null
      ? 'sshd is not installed'
      : null;

  late HerdrTestSession herdr;
  late TestSshd sshd;
  late SSHClient ssh;
  late HerdrLink link;
  late Directory config;
  late Directory dir;
  HerdrTestSession? startedHerdr;
  TestSshd? startedSshd;
  SSHClient? openSsh;

  setUpAll(() async {
    if (skip != null) return;
    config = await Directory.systemTemp.createTemp('shellherd-claude-');
    dir = await Directory('${config.path}/projects/-tmp-app')
        .create(recursive: true);
    await Future.wait([
      HerdrTestSession.start().then((h) => herdr = startedHerdr = h),
      TestSshd.start(env: {'CLAUDE_CONFIG_DIR': config.path})
          .then((s) => sshd = startedSshd = s),
    ]);
    ssh = openSsh = await sshd.connect();
    link = await HerdrLink.connect(ssh, session: herdr.name);
  });
  tearDownAll(() async {
    openSsh?.close();
    await startedSshd?.stop();
    await startedHerdr?.stop();
    if (skip == null) await config.delete(recursive: true);
  });

  /// Tells herdr, as its Claude hook does at SessionStart, that the agent
  /// of [pane] runs session [id], whose transcript is at [path]. herdr
  /// replaces a session only for a [start] of `clear` or `resume`.
  Future<void> report(
    String pane,
    String path,
    String id, {
    String start = 'startup',
  }) => herdr.client.request('pane.report_agent_session', {
    'pane_id': pane,
    'source': 'herdr:claude',
    'agent': 'claude',
    'seq': DateTime.now().microsecondsSinceEpoch * 1000,
    'agent_session_id': id,
    'agent_session_path': path,
    'session_start_source': start,
  });

  group('a reported transcript', skip: skip ?? false, () {
    test('reaches the snapshot as a session id, and a read over ssh finds '
        'and follows its transcript', () async {
      final pane = await herdr.createWorkspace('chat');
      final file = File('${dir.path}/s1.jsonl');
      await file.writeAsString('${claudeUser('first', uuid: 'u1')}\n');
      await report(pane, file.path, 's1');

      final snapshot = await link.client.snapshot();
      final session = snapshot.pane(pane)!.agentSession;
      // herdr keeps the id, not the path the hook also sends.
      expect(session?.kind, AgentSessionKind.id);
      expect(session?.claudeSession, 's1');

      final opener = sshTranscriptOpener(ssh);
      final stream = TranscriptStream(
        () => opener,
        () => 's1',
        changes: ValueNotifier(0),
      )..running = true;
      addTearDown(stream.dispose);
      await until(
        () => stream.view.value.items?.isNotEmpty ?? false,
        'the first message',
      );
      expect(stream.view.value.items, const [ChatPrompt('first')]);
      await file.writeAsString(
        '${claudeAssistant([claudeText('second')], uuid: 'a1')}\n',
        mode: FileMode.append,
      );
      await until(
        () => stream.view.value.items?.length == 2,
        'the appended message',
      );
      expect(stream.view.value.items!.last, const ChatReply('second'));
    });

    test('a big transcript loads back to its start over ssh, the same as '
        'one read of all of it', () async {
      // Six MiB: several loads of the tail.
      final pad = 'é' * 100000;
      final lines = [
        for (var i = 0; i < 60; i++)
          i.isEven
              ? claudeUser('prompt $i $pad', uuid: 'u$i')
              : claudeAssistant([
                  claudeToolUse('t$i', 'Bash', {'command': 'echo $i'}),
                ], uuid: 'a$i'),
        for (var i = 1; i < 60; i += 2)
          claudeUser([claudeToolResult('t$i', 'out $i')], uuid: 'r$i'),
      ];
      await File('${dir.path}/big.jsonl')
          .writeAsString(lines.map((l) => '$l\n').join());
      final opener = sshTranscriptOpener(ssh);
      final ranges = sshTranscriptRangeReader(ssh);
      final stream = TranscriptStream(
        () => opener,
        () => 'big',
        changes: ValueNotifier(0),
        ranges: () => ranges,
      )..running = true;
      addTearDown(stream.dispose);
      await until(
        () => stream.view.value.items?.isNotEmpty ?? false,
        'the end of the transcript',
      );
      expect(stream.view.value.startsCut, isTrue);
      var loads = 0;
      while (stream.view.value.startsCut) {
        await stream.loadEarlier();
        expect(stream.view.value.earlier, EarlierLoad.idle);
        expect(++loads, lessThan(10));
      }
      expect(loads, greaterThan(1));
      final want = ClaudeTranscript();
      lines.forEach(want.add);
      expect(stream.view.value.items, want.items);
    });

    test(
      'a session whose transcript is not written yet waits for it',
      () async {
        final opener = sshTranscriptOpener(ssh);
        final stream = TranscriptStream(
          () => opener,
          () => 'late',
          changes: ValueNotifier(0),
        )..running = true;
        addTearDown(stream.dispose);
        await until(
          () => stream.view.value.items?.isEmpty ?? false,
          'an empty chat',
        );
        expect(stream.unavailable.value, isFalse);
        await File('${dir.path}/late.jsonl')
            .writeAsString('${claudeUser('late', uuid: 'u1')}\n');
        await until(
          () => stream.view.value.items?.length == 1,
          'the first message',
        );
      },
    );

    test('a new link goes on where the last read stopped and gets only '
        'what was added since', () async {
      final file = File('${dir.path}/r1.jsonl');
      // No uuids: a record read twice would show twice.
      final first = '${claudeUser('first')}\n';
      await file.writeAsString(first);
      final reads = <_Recorded>[];
      TranscriptOpener recording() {
        final opener = sshTranscriptOpener(ssh);
        return (session, from) async {
          final read = _Recorded(await opener(session, from), from);
          reads.add(read);
          return read;
        };
      }

      var opener = recording();
      final changes = ValueNotifier(0);
      final stream = TranscriptStream(
        () => opener,
        () => 'r1',
        changes: changes,
      )..running = true;
      addTearDown(stream.dispose);
      await until(
        () => stream.view.value.items?.length == 1,
        'the first message',
      );
      // The link goes; a record comes while there is none.
      stream.running = false;
      final second = '${claudeAssistant([claudeText('second')])}\n';
      await file.writeAsString(second, mode: FileMode.append);
      opener = recording();
      changes.value++;
      stream.running = true;
      await until(
        () => stream.view.value.items?.length == 2,
        'the added message',
      );
      expect(stream.view.value.items, const [
        ChatPrompt('first'),
        ChatReply('second'),
      ]);
      expect(reads, hasLength(2));
      final inode = (await Process.run('stat', [
        '-c',
        '%i',
        file.path,
      ])).stdout.toString().trim();
      expect(reads.last.from, (
        inode: inode,
        line: 0,
        offset: utf8.encode(first).length,
      ));
      // The last line read comes again, for the check.
      final size = utf8.encode(first + second).length;
      expect(
        utf8.decode(reads.last.received),
        '$transcriptHeader$size 0 $inode\n$first$second',
      );
    });

    test('the session after /clear reaches the connection', () async {
      final pane = await herdr.createWorkspace('clear');
      await report(pane, '${dir.path}/before.jsonl', 'before');
      final connection = HerdrConnection(
        () async => OpenLink.herdr(
          link.client,
          transcripts: sshTranscriptOpener(ssh),
          done: Completer<void>().future,
          close: () {},
        ),
      )..connect();
      addTearDown(connection.dispose);
      String? session() =>
          connection.snapshot.value?.pane(pane)?.agentSession?.claudeSession;
      await until(() => session() == 'before', 'the first');
      await report(pane, '${dir.path}/after.jsonl', 'after', start: 'clear');
      expect(
        (await link.client.snapshot()).pane(pane)?.agentSession?.claudeSession,
        'after',
      );
      // herdr sends no event for a new session: the cache's periodic
      // refresh brings it.
      await until(
        () => session() == 'after',
        'the new session',
        within: HerdrCache.defaultRefreshEvery * 2,
      );
    });
  });
}

/// A read that keeps what it received.
class _Recorded implements TranscriptChannel {
  _Recorded(this._read, this.from);

  final TranscriptChannel _read;

  /// Where the stream asked the read to go on.
  final TranscriptMark? from;
  final received = <int>[];

  @override
  Stream<List<int>> get output => _read.output.map((bytes) {
    received.addAll(bytes);
    return bytes;
  });

  @override
  void close() => _read.close();
}
