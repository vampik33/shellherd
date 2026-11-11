import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/hc_client.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/hc_cache.dart';

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
}
