import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/herdr_cache.dart';

import '../support/fake_herdr.dart';
import '../support/poll.dart';

const _settle = Duration(milliseconds: 30);

void main() {
  late FakeHerdr herdr;
  late HerdrCache cache;
  late List<HerdrSnapshot> published;

  /// The number of the snapshot that was published last.
  int lastNumber() => published.last.workspaces.single.number;

  HerdrCache build({
    Duration debounce = const Duration(milliseconds: 5),
    Duration refreshEvery = const Duration(minutes: 1),
  }) => HerdrCache(
    herdr.client,
    onSnapshot: published.add,
    debounce: debounce,
    refreshEvery: refreshEvery,
  );

  setUp(() {
    herdr = FakeHerdr();
    published = [];
    cache = build();
  });
  tearDown(() => cache.close());

  group('HerdrCache', () {
    test('subscribes for the panes, and only then trusts a snapshot', () async {
      await cache.start();
      expect(herdr.methods, [
        'session.snapshot',
        'events.subscribe',
        'session.snapshot',
      ]);
      expect(herdr.watched, ['w1:p1']);
      expect(published.map((s) => s.workspaces.single.number), [2]);
    });

    test('an event brings a new snapshot, on the same subscription', () async {
      await cache.start();
      herdr.push();
      await until(() => published.length == 2, 'a second snapshot');
      expect(lastNumber(), 3);
      expect(herdr.count('events.subscribe'), 1);
    });

    test('a burst of events costs one snapshot', () async {
      cache = build(debounce: const Duration(milliseconds: 40));
      await cache.start();
      for (var i = 0; i < 20; i++) {
        herdr.push();
      }
      await until(() => published.length == 2, 'a second snapshot');
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(published, hasLength(2));
    });

    test('a steady stream of events cannot hold the update back', () async {
      cache = build(debounce: const Duration(milliseconds: 30));
      await cache.start();
      final pushing = Timer.periodic(
        const Duration(milliseconds: 5),
        (_) => herdr.push(),
      );
      addTearDown(pushing.cancel);
      await until(() => published.length >= 3, 'updates during the stream');
    });

    test('it reads a snapshot now and then without any event', () async {
      cache = build(refreshEvery: const Duration(milliseconds: 5));
      await cache.start();
      await until(() => published.length >= 3, 'refreshes');
      expect(herdr.count('events.subscribe'), 1);
    });

    test('a refresh that gets no answer ends the cache', () async {
      cache = build(refreshEvery: const Duration(milliseconds: 5));
      await cache.start();
      herdr.errors['session.snapshot'] = ['internal'];
      expect(await cache.lost, isA<HerdrApiException>());
    });

    test('close stops the refreshes', () async {
      cache = build(refreshEvery: const Duration(milliseconds: 2));
      await cache.start();
      await cache.close();
      final after = herdr.count('session.snapshot');
      await Future<void>.delayed(_settle);
      expect(herdr.count('session.snapshot'), after);
    });

    test('a new pane replaces the subscription, then reads again', () async {
      await cache.start();
      final first = herdr.subscriptions.single;
      herdr.panes = ['w1:p1', 'w1:p2'];
      herdr.methods.clear();
      herdr.push();
      await until(() => published.length == 2, 'a snapshot with the new pane');
      expect(herdr.methods, [
        'session.snapshot',
        'events.subscribe',
        'session.snapshot',
      ]);
      expect(herdr.watched, ['w1:p1', 'w1:p2']);
      expect(published.last.panes, hasLength(2));
      await until(() => first.closed, 'the old subscription to close');
      expect(herdr.subscriptions.last.closed, isFalse);
    });

    test('the old subscription works until the new one has started', () async {
      await cache.start();
      final first = herdr.subscriptions.single;
      herdr.panes = ['w1:p1', 'w1:p2'];
      herdr.holdSubscribes = Completer();
      herdr.push();
      await until(
        () => herdr.count('events.subscribe') == 2,
        'the second subscribe',
      );
      expect(first.closed, isFalse);
      herdr.holdSubscribes!.complete();
      await until(() => first.closed, 'the old subscription to close');
    });

    test('an event during a snapshot brings another snapshot', () async {
      await cache.start();
      herdr.holdSnapshots = Completer();
      herdr.push();
      await until(() => herdr.count('session.snapshot') == 3, 'the read');
      herdr.push(); // The reply is on its way, without this change.
      await Future<void>.delayed(_settle);
      herdr.holdSnapshots!.complete();
      herdr.holdSnapshots = null;
      await until(() => published.length == 3, 'one more snapshot');
      expect(lastNumber(), 4);
    });

    test('a pane that closed before the subscribe does no harm', () async {
      herdr.errors['events.subscribe'] = ['pane_not_found'];
      await cache.start();
      expect(herdr.count('events.subscribe'), 2);
      expect(published, hasLength(1));
    });

    test('a subscribe rejected every time gives up', () async {
      herdr.errors['events.subscribe'] = List.filled(
        9,
        'pane_not_found',
        growable: true,
      );
      await expectLater(cache.start(), throwsA(isA<HerdrApiException>()));
      expect(herdr.count('events.subscribe'), 5);
    });

    test('another subscribe error fails at once', () async {
      herdr.errors['events.subscribe'] = ['invalid_request'];
      await expectLater(cache.start(), throwsA(isA<HerdrApiException>()));
      expect(herdr.count('events.subscribe'), 1);
    });

    test('events_lost ends the cache with that cause', () async {
      await cache.start();
      herdr.subscriptions.last.reply({
        'error': {'code': 'events_lost', 'message': 'too slow'},
      });
      expect(
        await cache.lost,
        isA<HerdrApiException>().having((e) => e.code, 'code', 'events_lost'),
      );
    });

    test('a subscription that ends ends the cache', () async {
      await cache.start();
      herdr.subscriptions.last.end();
      expect(await cache.lost, isA<HerdrConnectionClosedException>());
    });

    test('a snapshot that fails after an event ends the cache', () async {
      await cache.start();
      herdr.errors['session.snapshot'] = ['internal'];
      herdr.push();
      expect(await cache.lost, isA<HerdrApiException>());
    });

    test('replacing the subscription does not count as lost', () async {
      await cache.start();
      herdr.panes = ['w1:p2'];
      herdr.push();
      await until(() => published.length == 2, 'the new pane set');
      var lost = false;
      unawaited(cache.lost.then((_) => lost = true));
      await Future<void>.delayed(_settle);
      expect(lost, isFalse);
    });

    test('close releases the subscription and stops updates', () async {
      await cache.start();
      await cache.close();
      expect(herdr.subscriptions.single.closed, isTrue);
      herdr.push();
      await Future<void>.delayed(_settle);
      expect(published, hasLength(1));
    });

    test('a snapshot that arrives after close is dropped', () async {
      await cache.start();
      herdr.holdSnapshots = Completer();
      herdr.push();
      await until(() => herdr.count('session.snapshot') == 3, 'the read');
      await cache.close();
      herdr.holdSnapshots!.complete();
      await Future<void>.delayed(_settle);
      expect(published, hasLength(1));
    });

    test('a subscribe that arrives after close is released', () async {
      herdr.holdSubscribes = Completer();
      final started = cache.start();
      await until(() => herdr.subscriptions.isNotEmpty, 'the subscribe');
      await cache.close();
      herdr.holdSubscribes!.complete();
      await started;
      await until(() => herdr.subscriptions.single.closed, 'the release');
      expect(published, isEmpty);
    });
  });
}
