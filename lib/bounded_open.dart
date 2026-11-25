import 'dart:async';

/// Waits up to [timeout] for [open], else throws [TimeoutException].
/// `Future.timeout` does not cancel the open, so a result that arrives late
/// goes to [discard] to release it.
Future<T> boundedOpen<T>(
  Future<T> open,
  Duration timeout,
  void Function(T late) discard,
) async {
  try {
    return await open.timeout(timeout);
  } on TimeoutException {
    unawaited(open.then<void>(discard, onError: (Object _) {}));
    rethrow;
  }
}
