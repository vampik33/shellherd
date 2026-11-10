/// Everything [HerdrClient] throws.
sealed class HerdrException implements Exception {
  const HerdrException();
}

/// herdr answered with `{"error": {"code", "message"}}`.
///
/// Codes seen on herdr 0.9.5 include `pane_not_found`, `agent_not_found`,
/// `agent_blocked`, `invalid_request` and, on a subscription, `events_lost`.
class HerdrApiException extends HerdrException {
  const HerdrApiException(this.method, this.code, this.message);
  final String method;
  final String code;
  final String message;

  @override
  String toString() => 'HerdrApiException($method): $code: $message';
}

/// herdr sent something this client cannot read: bad JSON, a wrong id, a
/// missing field, or a reply type that does not fit the request.
class HerdrProtocolException extends HerdrException {
  const HerdrProtocolException(this.message);
  final String message;

  @override
  String toString() => 'HerdrProtocolException: $message';
}

/// The dialer could not open a channel: no server, no socket, or no SSH link.
class HerdrConnectException extends HerdrException {
  const HerdrConnectException(this.method, this.cause);
  final String method;
  final Object cause;

  @override
  String toString() => 'HerdrConnectException: $method: $cause';
}

/// The connection ended before herdr sent a reply.
class HerdrConnectionClosedException extends HerdrException {
  const HerdrConnectionClosedException(this.method);
  final String method;

  @override
  String toString() =>
      'HerdrConnectionClosedException: $method: closed before a reply';
}

/// No reply came within the timeout. A mutation may still have been applied.
class HerdrTimeoutException extends HerdrException {
  const HerdrTimeoutException(this.method, this.timeout);
  final String method;
  final Duration timeout;

  @override
  String toString() =>
      'HerdrTimeoutException: $method: no reply in ${timeout.inMilliseconds} ms';
}
