import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';

import '../support/fake_channel.dart';

void main() {
  late FakeDialer dialer;
  late HerdrClient client;

  setUp(() {
    dialer = FakeDialer();
    client = HerdrClient(dialer.call, timeout: const Duration(seconds: 2));
  });

  /// Starts [call], plays [respond] as the server on its channel, and
  /// returns the call's future and the channel.
  Future<(Future<T>, FakeChannel)> serve<T>(
    Future<T> Function() call,
    void Function(FakeChannel ch, Map<String, Object?> req) respond,
  ) async {
    final nextChannel = dialer.next;
    final future = call();
    final ch = await nextChannel;
    respond(ch, await ch.request);
    return (future, ch);
  }

  void ok(FakeChannel ch, Map<String, Object?> req, Map<String, Object?> result) =>
      ch.reply({'id': req['id'], 'result': result});

  group('request', () {
    test('sends one envelope and closes the channel after the reply', () async {
      final (f, ch) = await serve(client.ping, (ch, req) {
        expect(req, {'id': 'sh-1', 'method': 'ping', 'params': <String, Object?>{}});
        ok(ch, req, {
          'type': 'pong',
          'version': '0.9.5',
          'protocol': 22,
          'capabilities': {'health_check': true},
          'future_field': 'ignored',
        });
      });
      final pong = await f;
      expect(pong.version, '0.9.5');
      expect(pong.protocol, 22);
      expect(pong.capabilities['health_check'], true);
      expect(ch.sent, hasLength(1));
      expect(ch.closed, isTrue);
    });

    test('each request dials its own channel with a new id', () async {
      final (f1, c1) = await serve(client.ping, (ch, req) {
        ok(ch, req, {'type': 'pong', 'version': 'v', 'protocol': 22});
      });
      final (f2, c2) = await serve(client.ping, (ch, req) {
        ok(ch, req, {'type': 'pong', 'version': 'v', 'protocol': 22});
      });
      await Future.wait([f1, f2]);
      expect(dialer.channels, hasLength(2));
      expect(c1.sent.single['id'], isNot(c2.sent.single['id']));
    });

    test('an error reply becomes HerdrApiException with code and message', () async {
      final (f, ch) = await serve(
        () => client.paneRead('w9:p9'),
        (ch, req) => ch.reply({
          'id': req['id'],
          'error': {'code': 'pane_not_found', 'message': 'pane w9:p9 not found'},
        }),
      );
      await expectLater(
        f,
        throwsA(
          isA<HerdrApiException>()
              .having((e) => e.code, 'code', 'pane_not_found')
              .having((e) => e.method, 'method', 'pane.read'),
        ),
      );
      expect(ch.closed, isTrue);
    });

    test('an error with an empty id still answers this request', () async {
      final (f, _) = await serve(
        client.ping,
        (ch, req) => ch.reply({
          'id': '',
          'error': {'code': 'invalid_request', 'message': 'bad'},
        }),
      );
      await expectLater(
        f,
        throwsA(isA<HerdrApiException>().having((e) => e.code, 'code', 'invalid_request')),
      );
    });

    test('a reply with another id is a protocol error', () async {
      final (f, _) = await serve(
        client.ping,
        (ch, req) => ch.reply({
          'id': 'someone-else',
          'result': {'type': 'pong', 'version': 'v', 'protocol': 22},
        }),
      );
      await expectLater(f, throwsA(isA<HerdrProtocolException>()));
    });

    test('a result of the wrong type is a protocol error', () async {
      final (f, _) = await serve(client.ping, (ch, req) => ok(ch, req, {'type': 'ok'}));
      await expectLater(
        f,
        throwsA(
          isA<HerdrProtocolException>().having((e) => e.message, 'message', contains('"pong"')),
        ),
      );
    });

    test('a missing required field is a protocol error', () async {
      final (f, _) = await serve(
        client.ping,
        (ch, req) => ok(ch, req, {'type': 'pong', 'protocol': 22}),
      );
      await expectLater(
        f,
        throwsA(
          isA<HerdrProtocolException>().having((e) => e.message, 'message', contains('version')),
        ),
      );
    });

    test('garbage from the server is a protocol error', () async {
      final (f, ch) = await serve(client.ping, (ch, req) => ch.replyRaw(utf8.encode('oops\n')));
      await expectLater(f, throwsA(isA<HerdrProtocolException>()));
      expect(ch.closed, isTrue);
    });

    test('EOF before a reply is HerdrConnectionClosedException', () async {
      final (f, _) = await serve(client.ping, (ch, req) => ch.end());
      await expectLater(f, throwsA(isA<HerdrConnectionClosedException>()));
    });

    test('no reply in time is HerdrTimeoutException and closes the channel', () async {
      final fast = HerdrClient(dialer.call, timeout: const Duration(milliseconds: 50));
      final (f, ch) = await serve(fast.ping, (ch, req) {});
      await expectLater(
        f,
        throwsA(isA<HerdrTimeoutException>().having((e) => e.method, 'method', 'ping')),
      );
      expect(ch.closed, isTrue);
    });

    test('a dial failure is HerdrConnectException', () async {
      dialer.failWith = const SocketException('Connection refused');
      await expectLater(
        client.ping(),
        throwsA(
          isA<HerdrConnectException>()
              .having((e) => e.cause, 'cause', isA<SocketException>()),
        ),
      );
    });
  });

  group('typed methods send the documented params', () {
    Future<Map<String, Object?>> capture(
      Future<Object?> Function() call,
      Map<String, Object?> result,
    ) async {
      late Map<String, Object?> sent;
      final (f, _) = await serve(call, (ch, req) {
        sent = req;
        ok(ch, req, result);
      });
      await f;
      return sent;
    }

    const read = {
      'type': 'pane_read',
      'read': {
        'pane_id': 'w1:p1',
        'workspace_id': 'w1',
        'tab_id': 'w1:t1',
        'source': 'visible',
        'format': 'ansi',
        'text': '\u001b[32mok\u001b[0m',
        'revision': 3,
        'truncated': false,
      },
    };

    test('pane.read with ansi asks herdr to keep escapes', () async {
      final req = await capture(
        () => client.paneRead(
          'w1:p1',
          source: ReadSource.visible,
          format: ReadFormat.ansi,
          lines: 40,
        ),
        read,
      );
      expect(req['method'], 'pane.read');
      expect(req['params'], {
        'pane_id': 'w1:p1',
        'source': 'visible',
        'format': 'ansi',
        'lines': 40,
        'strip_ansi': false,
      });
    });

    test('pane.read text omits lines and strip_ansi when not set', () async {
      final req = await capture(() => client.paneRead('w1:p1'), read);
      expect(req['params'], {
        'pane_id': 'w1:p1',
        'source': 'recent_unwrapped',
        'format': 'text',
      });
    });

    test('pane.read parses the read result', () async {
      final (f, _) = await serve(() => client.paneRead('w1:p1'), (ch, req) => ok(ch, req, read));
      final r = await f;
      expect(r.text, '\u001b[32mok\u001b[0m');
      expect(r.source, ReadSource.visible);
      expect(r.format, ReadFormat.ansi);
      expect(r.revision, 3);
    });

    test('pane.send_input sends text then keys', () async {
      final req = await capture(
        () => client.paneSendInput('w1:p1', text: 'ls', keys: ['enter']),
        {'type': 'ok'},
      );
      expect(req['params'], {
        'pane_id': 'w1:p1',
        'text': 'ls',
        'keys': ['enter'],
      });
    });

    test('pane.send_input with nothing to send is rejected before dialing', () {
      expect(() => client.paneSendInput('w1:p1'), throwsArgumentError);
      expect(dialer.channels, isEmpty);
    });

    test('pane.send_keys', () async {
      final req = await capture(() => client.paneSendKeys('w1:p1', ['ctrl+c']), {'type': 'ok'});
      expect(req['params'], {
        'pane_id': 'w1:p1',
        'keys': ['ctrl+c'],
      });
    });

    test('agent.prompt', () async {
      final req = await capture(
        () => client.agentPrompt('reviewer', 'status?'),
        {'type': 'agent_prompted'},
      );
      expect(req['params'], {'target': 'reviewer', 'text': 'status?'});
    });
  });

  group('subscribe', () {
    final subs = [
      const Subscription.lifecycle('workspace.created'),
      const Subscription.agentStatus('w1:p1'),
    ];

    Future<(HerdrSubscription, FakeChannel)> open() async {
      final (f, ch) = await serve(() => client.subscribe(subs), (ch, req) {
        expect(req['params'], {
          'subscriptions': [
            {'type': 'workspace.created'},
            {'type': 'pane.agent_status_changed', 'pane_id': 'w1:p1'},
          ],
        });
        ok(ch, req, {'type': 'subscription_started'});
      });
      return (await f, ch);
    }

    test('pushes events after the acknowledgement on the same channel', () async {
      final (sub, ch) = await open();
      expect(ch.closed, isFalse);
      ch.reply({
        'event': 'pane_agent_status_changed',
        'data': {
          'type': 'pane_agent_status_changed',
          'pane_id': 'w1:p1',
          'workspace_id': 'w1',
          'agent_status': 'blocked',
        },
      });
      ch.reply({
        'event': 'workspace_created',
        'data': {
          'type': 'workspace_created',
          'workspace': {'workspace_id': 'w2'},
        },
      });
      ch.end();
      final events = await sub.events.toList();
      expect(events.map((e) => e.kind), ['pane_agent_status_changed', 'workspace_created']);
      expect(events[0].paneId, 'w1:p1');
      expect(events[0].agentStatus, AgentStatus.blocked);
      expect(events[1].workspaceId, 'w2');
      expect(events[1].agentStatus, isNull);
      expect(ch.closed, isTrue);
    });

    test('events_lost ends the stream with HerdrApiException', () async {
      final (sub, ch) = await open();
      ch.reply({
        'id': 'sh-1',
        'error': {'code': 'events_lost', 'message': 'subscriber fell behind'},
      });
      await expectLater(
        sub.events,
        emitsInOrder([
          emitsError(isA<HerdrApiException>().having((e) => e.code, 'code', 'events_lost')),
          emitsDone,
        ]),
      );
      expect(ch.closed, isTrue);
    });

    test('a rejected subscribe throws and closes the channel', () async {
      final (f, ch) = await serve(
        () => client.subscribe(subs),
        (ch, req) => ch.reply({
          'id': req['id'],
          'error': {'code': 'pane_not_found', 'message': 'pane w1:p1 not found'},
        }),
      );
      await expectLater(
        f,
        throwsA(isA<HerdrApiException>().having((e) => e.code, 'code', 'pane_not_found')),
      );
      expect(ch.closed, isTrue);
    });

    test('cancelling the listener closes the channel', () async {
      final (sub, ch) = await open();
      final listener = sub.events.listen((_) {});
      await listener.cancel();
      expect(ch.closed, isTrue);
    });

    test('close before listening releases the channel', () async {
      final (sub, ch) = await open();
      await sub.close();
      expect(ch.closed, isTrue);
      expect(await sub.events.toList(), isEmpty);
    });
  });

  test('an unknown agent status maps to unknown', () {
    expect(AgentStatus.fromWire('dreaming'), AgentStatus.unknown);
    expect(AgentStatus.fromWire(null), AgentStatus.unknown);
    expect(AgentStatus.fromWire('blocked'), AgentStatus.blocked);
  });

  test(
    'a dial that never completes times out; a late channel is closed',
    () async {
      final late = Completer<HerdrChannel>();
      final stalled = HerdrClient(
        () => late.future,
        timeout: const Duration(milliseconds: 50),
      );
      await expectLater(
        stalled.ping(),
        throwsA(
          isA<HerdrTimeoutException>().having(
            (e) => e.method,
            'method',
            'ping',
          ),
        ),
      );
      final channel = FakeChannel();
      late.complete(channel);
      await Future<void>.delayed(Duration.zero);
      expect(channel.closed, isTrue);
      expect(channel.sent, isEmpty);
    },
  );

  group('openWithin', () {
    const short = Duration(milliseconds: 50);

    test('returns a result that comes in time', () async {
      final discarded = <int>[];
      expect(await openWithin(Future.value(7), short, discarded.add, 'x'), 7);
      expect(discarded, isEmpty);
    });

    test('an open that never completes throws HerdrTimeoutException', () {
      expect(
        openWithin(Completer<int>().future, short, (_) {}, 'ssh channel open'),
        throwsA(
          isA<HerdrTimeoutException>()
              .having((e) => e.method, 'method', 'ssh channel open')
              .having((e) => e.timeout, 'timeout', short),
        ),
      );
    });

    test('a result that comes after the timeout is discarded', () async {
      final late = Completer<int>();
      final discarded = Completer<int>();
      await expectLater(
        openWithin(late.future, short, discarded.complete, 'x'),
        throwsA(isA<HerdrTimeoutException>()),
      );
      late.complete(9);
      expect(await discarded.future.timeout(const Duration(seconds: 1)), 9);
    });

    test('an error that comes after the timeout is not uncaught', () async {
      final late = Completer<int>();
      await expectLater(
        openWithin(late.future, short, (_) => fail('discarded'), 'x'),
        throwsA(isA<HerdrTimeoutException>()),
      );
      late.completeError(StateError('connection closed'));
      // An uncaught error would fail this test in the test zone.
      await Future<void>.delayed(short);
    });
  });
}
