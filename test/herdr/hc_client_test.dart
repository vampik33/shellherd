import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/hc_client.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/server_api.dart';

import '../support/fake_channel.dart';
import '../support/fake_hc.dart';

void main() {
  group('HcClient', () {
    late FakeHc hc;

    setUp(() => hc = FakeHc());

    test('says hello once and sends the quick requests on that channel', () async {
      final client = await hc.connect();
      expect(client.hello.version, '0.1.20');
      expect(hc.requests.first.$1, 'hello');
      expect(hc.requests.first.$2, {'generation': 1});
      await client.terminals();
      await client.layout();
      await client.terminal('t1');
      expect(hc.dialer.channels, hasLength(1));
      final sent = hc.dialer.channels.single.sent;
      expect(sent.map((m) => m['jsonrpc']).toSet(), {'2.0'});
      expect(sent.map((m) => m['id']).toSet(), hasLength(4));
    });

    test('reads and input go each on a channel of its own, closed after', () async {
      final client = await hc.connect();
      expect(await client.read('t1', lines: 400), 'hello');
      await client.keys('t1', ['esc']);
      await client.send('t1', 'hi');
      await pumpEventQueue();
      expect(hc.dialer.channels, hasLength(4));
      for (final c in hc.dialer.channels.skip(1)) {
        expect(c.sent.map((m) => m['method']), isNot(contains('hello')));
        expect(c.closed, isTrue);
      }
      expect(hc.dialer.channels.first.closed, isFalse);
    });

    test('a send that herdr-core holds back holds up no other request', () async {
      final client = await hc.connect();
      hc.holdSends = Completer();
      var sent = false;
      final send = client.send('t1', 'hi').then((_) => sent = true);
      await pumpEventQueue();
      await client.terminals();
      expect(await client.read('t1', lines: 0), 'hello');
      expect(sent, isFalse);
      hc.holdSends!.complete();
      await send;
    });

    test('input waits longer than the other requests', () async {
      final client = await hc.connect(
        timeout: const Duration(milliseconds: 50),
      );
      hc.holdSends = Completer();
      final send = client.send('t1', 'hi');
      await Future<void>.delayed(const Duration(milliseconds: 150));
      hc.holdSends!.complete();
      await send;
    });

    test('close fails a send on its way and releases its channel', () async {
      final client = await hc.connect();
      hc.holdSends = Completer();
      final send = expectLater(
        client.send('t1', 'hi'),
        throwsA(isA<HerdrConnectionClosedException>()),
      );
      await pumpEventQueue();
      await client.close();
      await send;
      expect(hc.dialer.channels.every((c) => c.closed), isTrue);
    });

    test('a core of another generation is a protocol error', () async {
      hc.generation = 2;
      await expectLater(hc.connect(), throwsA(isA<HerdrProtocolException>()));
      expect(hc.dialer.channels.single.closed, isTrue);
    });

    test('a failed dial is a connect error', () async {
      hc.dialer.failWith = StateError('no socket');
      await expectLater(
        hc.connect(),
        throwsA(
          isA<HerdrConnectException>().having(
            (e) => e.method,
            'method',
            'hello',
          ),
        ),
      );
    });

    test('replies find their request by id, in any order', () async {
      final dialer = FakeDialer();
      final next = dialer.next;
      final connected = HcClient.connect(dialer.call);
      final c = await next;
      c.reply({
        'jsonrpc': '2.0',
        'id': (await c.request)['id'],
        'result': {
          'generation': 1,
          'version': 'v',
          'core': {},
          'framed': false,
          'methods': [],
          'features': [],
        },
      });
      final client = await connected;
      final first = client.request('a');
      final second = client.request('b');
      await pumpEventQueue();
      final ids = [for (final m in c.sent.skip(1)) m['id']];
      c.reply({
        'jsonrpc': '2.0',
        'id': ids[1],
        'result': {'text': 'two'},
      });
      c.reply({
        'jsonrpc': '2.0',
        'id': ids[0],
        'result': {'text': 'one'},
      });
      expect(await first, {'text': 'one'});
      expect(await second, {'text': 'two'});
    });

    test('error kinds the app acts on become herdr codes', () async {
      final client = await hc.connect();
      hc.errors['terminal.read'] = ['not_found', 'finished'];
      hc.errors['terminal.send'] = ['blocked', 'unavailable'];
      Matcher code(String c) =>
          throwsA(isA<HerdrApiException>().having((e) => e.code, 'code', c));
      await expectLater(client.read('t9', lines: 0), code('pane_not_found'));
      await expectLater(client.read('t9', lines: 0), code('pane_not_found'));
      await expectLater(client.send('t1', 'hi'), code('agent_blocked'));
      await expectLater(client.send('t1', 'hi'), code('unavailable'));
    });

    test('a timed-out request does not block the next one', () async {
      final client = await hc.connect(
        timeout: const Duration(milliseconds: 50),
      );
      hc.silent.add('terminal.list');
      await expectLater(
        client.terminals(),
        throwsA(isA<HerdrTimeoutException>()),
      );
      expect((await client.layout()).spaces, hasLength(1));
    });

    test('the end of the channel fails what waits, and what comes', () async {
      final client = await hc.connect();
      hc.silent.add('terminal.list');
      final waiting = client.terminals();
      await pumpEventQueue();
      hc.dialer.channels.single.end();
      await expectLater(
        waiting,
        throwsA(isA<HerdrConnectionClosedException>()),
      );
      await client.done;
      await expectLater(
        client.read('t1', lines: 0),
        throwsA(isA<HerdrConnectionClosedException>()),
      );
    });

    test('a line that is not JSON fails what waits', () async {
      final client = await hc.connect();
      hc.silent.add('terminal.list');
      final waiting = client.terminals();
      await pumpEventQueue();
      hc.dialer.channels.single.replyRaw(utf8.encode('not json\n'));
      await expectLater(waiting, throwsA(isA<HerdrProtocolException>()));
    });

    test('keys needs keys', () async {
      final client = await hc.connect();
      expect(() => client.keys('t1', []), throwsArgumentError);
    });

    test('a subscription has a channel of its own and ends with it', () async {
      final client = await hc.connect();
      final sub = await client.subscribe();
      expect(hc.dialer.channels, hasLength(2));
      final notes = <String>[];
      final ended = Completer<void>();
      sub.notes.listen(notes.add, onDone: ended.complete);
      hc.note('heartbeat');
      hc.note('event');
      hc.subscriptions.single.end();
      await ended.future;
      expect(notes, ['heartbeat', 'event']);
      // The request channel lives on.
      expect(await client.read('t1', lines: 0), 'hello');
    });

    test('close releases the request channel', () async {
      final client = await hc.connect();
      await client.close();
      expect(hc.dialer.channels.single.closed, isTrue);
      await client.done;
    });
  });

  group('HcLayout', () {
    test('a document never written is no space', () {
      expect(HcLayout.fromJson(null).spaces, isEmpty);
    });

    test('terminals of a split tree come in layout order, mods left out', () {
      final layout = HcLayout.fromJson({
        'spaces': [
          {
            'id': 's',
            'tabs': [
              {
                'id': 'b',
                'root': {
                  'type': 'row',
                  'children': [
                    {
                      'type': 'block',
                      'content': {'terminal': 't1'},
                    },
                    {
                      'type': 'column',
                      'children': [
                        {
                          'type': 'block',
                          'content': {'mod': 'files'},
                        },
                        {
                          'type': 'block',
                          'content': {'terminal': 't2'},
                        },
                      ],
                    },
                  ],
                },
              },
            ],
          },
        ],
      });
      final tab = layout.spaces.single.tabs.single;
      expect(tab.terminals, ['t1', 't2']);
      expect(tab.name, '');
      expect(layout.spaces.single.name, '');
    });

    test('a layout that is no object is a protocol error', () {
      expect(
        () => HcLayout.fromJson([1]),
        throwsA(isA<HerdrProtocolException>()),
      );
    });
  });

  group('HcTerminal', () {
    test('takes the folder it is in now, and the status', () {
      final t = HcTerminal.fromJson(
        hcTerminal(
          't3',
          cwd: '/now',
          status: {'state': 'working', 'app': 'claude-code', 'msg': 'tests'},
          turn: 4,
        ),
      );
      expect(t.cwd, '/now');
      expect(t.live, isTrue);
      expect(t.status?.app, 'claude-code');
      expect(t.status?.msg, 'tests');
      expect(t.turn, 4);
    });

    test('a label that is not text is a protocol error', () {
      expect(
        () => HcTerminal.fromJson({
          ...hcTerminal('t1'),
          'labels': {'herdr.seen': 3},
        }),
        throwsA(isA<HerdrProtocolException>()),
      );
    });
  });

  group('HcPaneApi.submit', () {
    late FakeHc hc;

    setUp(() => hc = FakeHc());

    test('sends to an agent that still reports a status', () async {
      hc.terminals = [
        hcTerminal('t1', status: {'state': 'done', 'app': 'claude-code'}),
      ];
      final api = HcPaneApi(await hc.connect());
      await api.submit('t1', 'hi', toAgent: true);
      expect(hc.methods.skip(1), ['terminal.get', 'terminal.send']);
    });

    test(
      'refuses an agent that has quit to its shell, before sending',
      () async {
        // The snapshot still showed an agent; the core no longer does.
        hc.terminals = [hcTerminal('t1')];
        final api = HcPaneApi(await hc.connect());
        await expectLater(
          api.submit('t1', 'rm -r x', toAgent: true),
          throwsA(
            isA<HerdrApiException>().having(
              (e) => e.code,
              'code',
              'agent_not_ready',
            ),
          ),
        );
        expect(hc.methods, isNot(contains('terminal.send')));
      },
    );

    test('text for a shell goes without the check', () async {
      final api = HcPaneApi(await hc.connect());
      await api.submit('t1', 'ls', toAgent: false);
      expect(hc.methods.skip(1), ['terminal.send']);
    });
  });
}
