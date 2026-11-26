/// Runs [HerdrClient] against a real headless herdr server in a throwaway
/// named session. Skipped when `herdr` is not on PATH.
/// Run alone with: flutter test --tags herdr
@Tags(['herdr'])
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/pane_history.dart';
import 'package:shellherd/herdr/pane_poller.dart';
import 'package:shellherd/herdr/server_api.dart';

import '../support/herdr_test_session.dart';

Future<void> main() async {
  final available = await HerdrTestSession.herdrAvailable();
  late HerdrTestSession herdr;
  HerdrTestSession? started; // set only when start() succeeded

  setUpAll(() async {
    if (available) herdr = started = await HerdrTestSession.start();
  });
  tearDownAll(() async => started?.stop());

  group('herdr live', skip: available ? false : 'herdr is not on PATH', () {
    test('ping reports version, protocol 22 and capabilities', () async {
      final pong = await herdr.client.ping();
      expect(pong.version, isNotEmpty);
      expect(pong.protocol, 22);
      expect(pong.capabilities, contains('health_check'));
    });

    test('snapshot parses a workspace with its tab and pane', () async {
      final paneId = await herdr.createWorkspace('snap');
      final snap = await herdr.client.snapshot();
      final ws = snap.workspaces.singleWhere((w) => w.label == 'snap');
      final pane = snap.panes.singleWhere((p) => p.id == paneId);
      expect(pane.workspaceId, ws.id);
      expect(snap.protocol, 22);
    });

    test('send_input runs a command and pane.read returns its output', () async {
      final paneId = await herdr.createWorkspace('io');
      await herdr.client.paneSendInput(paneId, text: r'echo HELLO_$((40+2))', keys: ['enter']);
      final text = await herdr.waitForText(paneId, (t) => t.contains('HELLO_42'));
      // The shell expanded the arithmetic, so a command ran, not only an echo of input.
      expect(text, contains('HELLO_42'));
    });

    test('pane.read ansi keeps escape sequences, text strips them', () async {
      final paneId = await herdr.createWorkspace('ansi');
      await herdr.client.paneSendInput(
        paneId,
        text: r"printf '\033[31mRED_%s\033[0m\n' MARK",
        keys: ['enter'],
      );
      final ansi = await herdr.waitForText(
        paneId,
        (t) => t.contains('RED_MARK'),
        format: ReadFormat.ansi,
      );
      expect(ansi, contains('\u001b['));
      final plain = await herdr.client.paneRead(paneId, lines: 50);
      expect(plain, contains('RED_MARK'));
      expect(plain, isNot(contains('\u001b[')));
    });

    test('send_keys ctrl+c interrupts a running command', () async {
      final paneId = await herdr.createWorkspace('keys');
      await herdr.client.paneSendInput(paneId, text: 'sleep 60', keys: ['enter']);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await herdr.client.paneSendKeys(paneId, ['ctrl+c']);
      await herdr.client.paneSendInput(paneId, text: r'echo AFTER_$((1+1))', keys: ['enter']);
      // Without the interrupt, sleep 60 would hold the shell past the timeout.
      await herdr.waitForText(paneId, (t) => t.contains('AFTER_2'), timeout: const Duration(seconds: 5));
    });

    test('a deeper read holds the text view\'s read, with older lines above '
        'it; herdr gives at most 1000 lines', () async {
      final paneId = await herdr.createWorkspace('history');
      await herdr.client.paneSendInput(
        paneId,
        text: r'seq 1 3000; echo DONE_$((1+1))',
        keys: ['enter'],
      );
      await herdr.waitForText(paneId, (t) => t.contains('DONE_2'));
      final api = HerdrPaneApi(herdr.client);
      Future<List<String>> read(int lines) async => (await api.read(
        paneId,
        source: ReadSource.recentUnwrapped,
        lines: lines,
      )).split('\n');
      final shown = await read(PanePoller.historyLines);
      expect(shown, hasLength(PanePoller.historyLines));
      final deeper = await read(historySteps.first);
      // Fewer lines than asked for: the text view loads no more.
      expect(deeper.length, lessThan(historySteps.first));
      expect(deeper.length, greaterThan(shown.length));
      expect(olderLines(shown, deeper), deeper.length - shown.length);
    });

    test('agent.prompt on a pane without an agent is agent_not_found', () async {
      final paneId = await herdr.createWorkspace('noagent');
      await expectLater(
        herdr.client.agentPrompt(paneId, 'hello'),
        throwsA(isA<HerdrApiException>().having((e) => e.code, 'code', 'agent_not_found')),
      );
    });

    test('an unknown pane is pane_not_found', () async {
      await expectLater(
        herdr.client.paneRead('w999:p999'),
        throwsA(isA<HerdrApiException>().having((e) => e.code, 'code', 'pane_not_found')),
      );
    });

    test('subscribe pushes workspace and pane creation as events', () async {
      final sub = await herdr.client.subscribe(const [
        Subscription.lifecycle('workspace.created'),
        Subscription.lifecycle('pane.created'),
      ]);
      final seen = sub.events.take(2).toList(); // take() cancels, closing the channel
      final paneId = await herdr.createWorkspace('evented');
      final events = await seen.timeout(const Duration(seconds: 5));
      final ws = events.singleWhere((e) => e.kind == 'workspace_created');
      expect((ws.data['workspace']! as Map)['label'], 'evented');
      final pane = events.singleWhere((e) => e.kind == 'pane_created');
      expect(jsonEncode(pane.data), contains('"$paneId"'));
    });

    test('subscribing to the status of an unknown pane is rejected', () async {
      await expectLater(
        herdr.client.subscribe(const [Subscription.agentStatus('w999:p999')]),
        throwsA(isA<HerdrApiException>().having((e) => e.code, 'code', 'pane_not_found')),
      );
    });

    test('herdr closes a request connection after one reply', () async {
      // Guards the one-request-per-connection design: if herdr ever keeps the
      // socket open, this test fails and the transport can be simplified.
      final channel = await SocketHerdrChannel.dialer(herdr.socketPath)();
      channel.write(encodeNdjson({'id': 'once', 'method': 'ping', 'params': {}}));
      final lines = await decodeNdjson(channel.input).toList().timeout(const Duration(seconds: 5));
      expect(lines.single['id'], 'once');
      await channel.close();
    });
  });
}
