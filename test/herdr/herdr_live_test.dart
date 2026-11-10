/// Runs [HerdrClient] against a real headless herdr server in a throwaway
/// named session. Skipped when `herdr` is not on PATH.
/// Run alone with: flutter test --tags herdr
@Tags(['herdr'])
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';

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
      expect(snap.tabs.where((t) => t.workspaceId == ws.id), hasLength(ws.tabCount));
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
      expect(plain.text, contains('RED_MARK'));
      expect(plain.text, isNot(contains('\u001b[')));
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
      final events = StreamIterator(sub.events);
      try {
        final paneId = await herdr.createWorkspace('evented');
        final seen = <HerdrEvent>[];
        while (seen.length < 2 && await events.moveNext().timeout(const Duration(seconds: 5))) {
          seen.add(events.current);
        }
        final ws = seen.singleWhere((e) => e.kind == 'workspace_created');
        expect((ws.data['workspace']! as Map)['label'], 'evented');
        expect(seen.singleWhere((e) => e.kind == 'pane_created').paneId, paneId);
      } finally {
        await events.cancel();
      }
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
