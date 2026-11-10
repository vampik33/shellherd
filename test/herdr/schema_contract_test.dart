/// Checks every request HerdrClient sends against the request schema that
/// the installed herdr prints with `herdr api schema --json`. A herdr update
/// that renames a method or a param fails here before it fails on a phone.
@Tags(['herdr'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:json_schema/json_schema.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';

import '../support/fake_channel.dart';

Future<void> main() async {
  Map<String, Object?>? root;
  try {
    final r = await Process.run('herdr', ['api', 'schema', '--json']);
    if (r.exitCode == 0) root = jsonDecode(r.stdout as String) as Map<String, Object?>;
  } on ProcessException {
    root = null;
  }

  group('requests match herdr api schema', skip: root == null ? 'herdr is not on PATH' : false, () {
    late JsonSchema requestSchema;

    setUpAll(() {
      // The request schema lives at /schemas/request and refers to its defs
      // as "#/schemas/request/$defs/X". Lift it to a root document and
      // rebase those refs to "#/$defs/X".
      final request = jsonEncode((root!['schemas']! as Map)['request'])
          .replaceAll(r'#/schemas/request/$defs/', r'#/$defs/');
      expect(request, isNot(contains('#/schemas/')), reason: 'a ref left un-rebased');
      requestSchema = JsonSchema.create(
        jsonDecode(request),
        schemaVersion: SchemaVersion.draft2020_12,
      );
    });

    /// Runs [call] against a fake server that answers [result] and returns
    /// the request line the client wrote.
    Future<Map<String, Object?>> sent(
      Future<Object?> Function(HerdrClient c) call,
      Map<String, Object?> result,
    ) async {
      final dialer = FakeDialer();
      final client = HerdrClient(dialer.call);
      final next = dialer.next;
      final done = call(client);
      final ch = await next;
      final req = await ch.request;
      ch.reply({'id': req['id'], 'result': result});
      try {
        await done;
      } on HerdrProtocolException {
        // The fake results are sparse; only the request matters here.
      }
      return req;
    }

    void expectValid(Map<String, Object?> req) {
      final v = requestSchema.validate(req);
      expect(v.isValid, isTrue, reason: '${jsonEncode(req)}\n${v.errors.join('\n')}');
    }

    test('the gate rejects a request herdr would reject', () {
      // Proves the validator is live: pane.read without "source" is invalid.
      final v = requestSchema.validate({
        'id': 'x',
        'method': 'pane.read',
        'params': {'pane_id': 'w1:p1'},
      });
      expect(v.isValid, isFalse);
    });

    test('ping', () async => expectValid(await sent((c) => c.ping(), {'type': 'pong'})));

    test('session.snapshot', () async {
      expectValid(await sent((c) => c.snapshot(), {'type': 'session_snapshot'}));
    });

    test('pane.read, text and ansi', () async {
      expectValid(await sent((c) => c.paneRead('w1:p1'), {'type': 'pane_read'}));
      expectValid(
        await sent(
          (c) => c.paneRead('w1:p1', source: ReadSource.visible, format: ReadFormat.ansi, lines: 80),
          {'type': 'pane_read'},
        ),
      );
    });

    test('pane.send_input', () async {
      expectValid(
        await sent((c) => c.paneSendInput('w1:p1', text: 'ls', keys: ['enter']), {'type': 'ok'}),
      );
    });

    test('pane.send_keys', () async {
      expectValid(await sent((c) => c.paneSendKeys('w1:p1', ['ctrl+c', 'esc']), {'type': 'ok'}));
    });

    test('agent.prompt', () async {
      expectValid(await sent((c) => c.agentPrompt('w1:p1', 'hi'), {'type': 'agent_prompted'}));
    });

    test('events.subscribe', () async {
      expectValid(
        await sent(
          (c) => c.subscribe(const [
            Subscription.lifecycle('workspace.created'),
            Subscription.lifecycle('pane.closed'),
            Subscription.agentStatus('w1:p1'),
          ]),
          {'type': 'subscription_started'},
        ),
      );
    });
  });
}
