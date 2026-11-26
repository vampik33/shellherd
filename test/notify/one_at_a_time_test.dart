import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/notify/one_at_a_time.dart';

void main() {
  test('an action starts only after the one before it ended', () async {
    final queue = OneAtATime();
    final log = <String>[];
    final first = Completer<int>();
    final a = queue.run(() {
      log.add('start 1');
      return first.future;
    });
    final b = queue.run(() async {
      log.add('start 2');
      return 2;
    });
    await pumpEventQueue();
    expect(log, ['start 1'], reason: 'the second waits for the first');
    first.complete(1);
    expect(await a, 1);
    expect(await b, 2);
    expect(log, ['start 1', 'start 2']);
  });

  test('calls run in the order they came, never two at once', () async {
    final queue = OneAtATime();
    final order = <int>[];
    var running = 0;
    await Future.wait([
      for (var i = 0; i < 10; i++)
        queue.run(() async {
          expect(running, 0, reason: 'call $i overlaps another');
          running++;
          // Some calls take longer: a later call must still wait.
          for (var j = 0; j < 10 - i; j++) {
            await Future<void>.value();
          }
          order.add(i);
          running--;
        }),
    ]);
    expect(order, List.generate(10, (i) => i));
  });

  test('a failure reaches its caller and does not block the next', () async {
    final queue = OneAtATime();
    final failed = queue.run<int>(() async => throw StateError('async'));
    final thrown = queue.run<int>(() => throw StateError('sync'));
    final next = queue.run(() async => 'ok');
    await expectLater(failed, throwsA(isA<StateError>()));
    await expectLater(thrown, throwsA(isA<StateError>()));
    expect(await next, 'ok');
  });
}
