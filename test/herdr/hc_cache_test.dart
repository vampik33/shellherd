import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/hc_client.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/hc_cache.dart';
import 'package:shellherd/herdr/transcript/claude_sessions.dart';

import '../support/fake_hc.dart';
import '../support/poll.dart';

const _settle = Duration(milliseconds: 40);

void main() {
  late FakeHc hc;
  late HcClient client;
  late HcCache cache;
  late List<HerdrSnapshot> published;

  Future<HcCache> start({
    Duration stallAfter = const Duration(minutes: 1),
  }) async {
    cache = HcCache(
      client,
      onSnapshot: published.add,
      debounce: const Duration(milliseconds: 5),
      stallAfter: stallAfter,
    );
    await cache.start();
    return cache;
  }

  setUp(() async {
    hc = FakeHc();
    client = await hc.connect();
    published = [];
  });
  tearDown(() async {
    await cache.close();
    await client.close();
  });

  test('subscribes first, then publishes the first snapshot', () async {
    await start();
    expect(hc.methods.take(2), ['hello', 'events.subscribe']);
    expect(hc.methods.skip(2).toSet(), {'terminal.list', 'doc.get'});
    expect(published.single.panes.single.id, 't1');
  });

  test('a burst of events gives one new snapshot', () async {
    await start();
    hc.terminals = [...hc.terminals, hcTerminal('t2')];
    hc.note('event');
    hc.note('event');
    hc.note('event');
    await until(() => published.length == 2, 'a second snapshot');
    await Future<void>.delayed(_settle);
    expect(published, hasLength(2));
    expect(hc.count('terminal.list'), 2);
  });

  test('a fell-behind notice reads again; a heartbeat does not', () async {
    await start();
    hc.note('heartbeat');
    await Future<void>.delayed(_settle);
    expect(published, hasLength(1));
    hc.note('missed');
    await until(() => published.length == 2, 'a second snapshot');
  });

  test('an event during a read brings another read', () async {
    await start();
    final hold = hc.holdLists = Completer<void>();
    hc.note('event');
    await until(() => hc.count('terminal.list') == 2, 'the second read');
    hc.note('event');
    hc.holdLists = null;
    hold.complete();
    await until(() => published.length == 3, 'a third snapshot');
  });

  test('silence past stallAfter loses the link', () async {
    await start(stallAfter: const Duration(milliseconds: 60));
    expect(await cache.lost, isA<HerdrTimeoutException>());
  });

  test('heartbeats keep the link', () async {
    await start(stallAfter: const Duration(milliseconds: 60));
    var lost = false;
    unawaited(cache.lost.then((_) => lost = true));
    for (var i = 0; i < 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      hc.note('heartbeat');
    }
    expect(lost, isFalse);
  });

  test('the end of the subscription loses the link', () async {
    await start();
    hc.subscriptions.single.end();
    expect(await cache.lost, isA<HerdrConnectionClosedException>());
  });

  test('the end of the request channel loses the link', () async {
    await start();
    hc.dialer.channels.first.end();
    expect(await cache.lost, isA<HerdrConnectionClosedException>());
  });

  test('a failed read loses the link', () async {
    await start();
    hc.errors['doc.get'] = ['unavailable'];
    hc.note('event');
    expect(await cache.lost, isA<HerdrApiException>());
  });

  test('a failed first read fails start', () async {
    hc.errors['terminal.list'] = ['unavailable'];
    await expectLater(start(), throwsA(isA<HerdrApiException>()));
  });

  test('after close nothing is published', () async {
    await start();
    await cache.close();
    hc.note('event');
    await Future<void>.delayed(_settle);
    expect(published, hasLength(1));
  });

  group('Claude Code sessions', () {
    const id1 = '0d6c1f3e-1b2a-4c5d-8e9f-0a1b2c3d4e5f';
    const id2 = '142989e8-15e1-4adb-9046-7d45cb8b3666';
    late List<List<int>> lookups;
    late Map<int, String> files;

    Future<Map<int, String>> lookup(List<int> pids) async {
      lookups.add(pids);
      return {for (final p in pids) p: ?files[p]};
    }

    String? sessionOf(String pane) => published.last.panes
        .singleWhere((p) => p.id == pane)
        .agentSession
        ?.claudeSession;

    setUp(() {
      lookups = [];
      files = {7: id1};
      hc.terminals = [
        hcTerminal(
          't1',
          labels: {'herdr.space': 's1', 'herdr.tab': 'b1'},
          status: {'state': 'idle', 'app': 'claude-code'},
          pid: 7,
        ),
        hcTerminal(
          't2',
          labels: {'herdr.space': 's1', 'herdr.tab': 'b1'},
          pid: 8,
        ),
      ];
      hc.layout = {
        'spaces': [
          hcSpace('s1', [
            hcTab('b1', ['t1', 't2']),
          ]),
        ],
      };
    });

    test(
      'a found session comes in a new snapshot; /clear in a later one',
      () async {
        cache = HcCache(
          client,
          onSnapshot: published.add,
          debounce: const Duration(milliseconds: 5),
          claudeSessions: lookup,
          sessionRefresh: const Duration(milliseconds: 50),
        );
        await cache.start();
        await until(() => sessionOf('t1') == id1, 'the session');
        expect(lookups.first, [7], reason: 'only the Claude Code pane');
        expect(sessionOf('t2'), isNull);
        files[7] = id2;
        await until(() => sessionOf('t1') == id2, 'the new session');
      },
    );

    test('a Claude Code pane without a usable pid does not stop the lookup '
        'of the others', () async {
      hc.terminals = [
        ...hc.terminals,
        for (final (address, pid) in [('t3', 0), ('t4', -1)])
          hcTerminal(
            address,
            labels: {'herdr.space': 's1', 'herdr.tab': 'b1'},
            status: {'state': 'idle', 'app': 'claude-code'},
            pid: pid,
          ),
      ];
      cache = HcCache(
        client,
        onSnapshot: published.add,
        debounce: const Duration(milliseconds: 5),
        // As the SSH lookup does: its command refuses a pid that is not
        // one.
        claudeSessions: (pids) async {
          claudeSessionsCommand(pids);
          return lookup(pids);
        },
        sessionRefresh: const Duration(milliseconds: 50),
      );
      await cache.start();
      await until(() => sessionOf('t1') == id1, 'the session');
      expect(lookups.first, [7]);
      expect(sessionOf('t3'), isNull);
      expect(sessionOf('t4'), isNull);
    });

    test('without a lookup no pane has a session', () async {
      await start();
      await Future<void>.delayed(_settle);
      final panes = published.last.panes;
      expect(panes.map((p) => p.id), ['t1', 't2']);
      expect(panes.map((p) => p.agentSession), everyElement(isNull));
    });
  });
}
