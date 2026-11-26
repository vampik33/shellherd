/// Reads the transcript of a Claude Code session that a real herdr
/// reports, over a real SSH connection to a throwaway sshd on 127.0.0.1,
/// against a throwaway named herdr session. The transcripts live in a
/// throwaway CLAUDE_CONFIG_DIR, never in the user's ~/.claude. Skipped when `herdr` or `sshd` is missing.
/// Run alone with: flutter test test/herdr/transcript_live_test.dart
@Tags(['herdr', 'sshd'])
@Timeout(Duration(seconds: 90))
library;

import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/herdr_cache.dart';
import 'package:shellherd/herdr/herdr_connection.dart';
import 'package:shellherd/herdr/herdr_link.dart';
import 'package:shellherd/herdr/transcript/chat_items.dart';
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
