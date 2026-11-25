import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/bounded_open.dart';

void main() {
  const short = Duration(milliseconds: 50);

  test('returns a result that comes in time', () async {
    final discarded = <int>[];
    expect(await boundedOpen(Future.value(7), short, discarded.add), 7);
    expect(discarded, isEmpty);
  });

  test('an open that never completes throws TimeoutException', () {
    expect(
      boundedOpen(Completer<int>().future, short, (_) {}),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('a result that comes after the timeout is discarded', () async {
    final late = Completer<int>();
    final discarded = Completer<int>();
    await expectLater(
      boundedOpen(late.future, short, discarded.complete),
      throwsA(isA<TimeoutException>()),
    );
    late.complete(9);
    expect(await discarded.future.timeout(const Duration(seconds: 1)), 9);
  });

  test('an error that comes after the timeout is not uncaught', () async {
    final late = Completer<int>();
    await expectLater(
      boundedOpen(late.future, short, (_) => fail('discarded')),
      throwsA(isA<TimeoutException>()),
    );
    late.completeError(StateError('connection closed'));
    // An uncaught error would fail this test in the test zone.
    await Future<void>.delayed(short);
  });
}
