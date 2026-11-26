/// Runs actions one after another: each starts after the earlier ones
/// ended. A failed action fails only its own call, not the next.
class OneAtATime {
  var _last = Future<void>.value();

  Future<T> run<T>(Future<T> Function() action) {
    final next = _last.then((_) => action());
    _last = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }
}
