import 'dart:async';

import 'herdr_errors.dart';
import 'models.dart';
import 'ndjson_transport.dart';

export 'herdr_errors.dart';
export 'models.dart';
export 'ndjson_transport.dart';

/// Client for the herdr JSON socket API.
///
/// Each [request] dials its own channel, because herdr closes a connection
/// after one reply. [subscribe] keeps a dedicated channel open for events.
class HerdrClient {
  HerdrClient(
    this._dial, {
    this.timeout = const Duration(seconds: 15),
    this.idPrefix = 'sh',
  });

  final HerdrDialer _dial;

  /// Prefix of request ids, so herdr logs show which client sent what.
  final String idPrefix;

  /// Default time to wait for the channel to open, and then again for the
  /// reply. A dialer over a stalled network can hang, so the dial is bounded
  /// too.
  final Duration timeout;

  var _seq = 0;

  String _nextId() => '$idPrefix-${++_seq}';

  /// Sends one raw request and returns its `result` object.
  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    final (channel, lines, result) = await _exchange(method, params, timeout);
    await lines.cancel();
    await channel.close();
    return result;
  }

  Future<HerdrPing> ping() async =>
      HerdrPing.fromJson(await _call('ping', 'pong'));

  Future<HerdrSnapshot> snapshot() async {
    const method = 'session.snapshot';
    final r = await _call(method, 'session_snapshot');
    return HerdrSnapshot.fromJson(_field(r, 'snapshot', method));
  }

  /// Reads pane text. With [ReadFormat.ansi] the escape sequences are kept.
  Future<PaneRead> paneRead(
    String paneId, {
    ReadSource source = ReadSource.recentUnwrapped,
    ReadFormat format = ReadFormat.text,
    int? lines,
  }) async {
    const method = 'pane.read';
    final r = await _call(method, 'pane_read', {
      'pane_id': paneId,
      'source': source.wire,
      'format': format.name,
      'lines': ?lines,
      if (format == ReadFormat.ansi) 'strip_ansi': false,
    });
    return PaneRead.fromJson(_field(r, 'read', method));
  }

  /// Sends literal [text], then herdr key names such as `enter`, in order.
  /// Success means herdr queued the input, not that a command ran.
  Future<void> paneSendInput(
    String paneId, {
    String? text,
    List<String> keys = const [],
  }) async {
    if (text == null && keys.isEmpty) {
      throw ArgumentError('paneSendInput needs text or keys');
    }
    await _call('pane.send_input', 'ok', {
      'pane_id': paneId,
      'text': ?text,
      if (keys.isNotEmpty) 'keys': keys,
    });
  }

  /// Sends herdr key names: `esc`, `enter`, `ctrl+c`, `up`, `f1`, ...
  Future<void> paneSendKeys(String paneId, List<String> keys) async {
    if (keys.isEmpty) throw ArgumentError('paneSendKeys needs keys');
    await _call('pane.send_keys', 'ok', {'pane_id': paneId, 'keys': keys});
  }

  /// Submits [text] plus Enter to the agent in [target] (a pane id or a live
  /// agent name). herdr rejects a blocked agent with `agent_blocked`.
  Future<void> agentPrompt(String target, String text) async {
    await _call('agent.prompt', 'agent_prompted', {
      'target': target,
      'text': text,
    });
  }

  /// Opens an event subscription. Returns after herdr acknowledges it.
  ///
  /// herdr does not replay events from before the acknowledgement, so take
  /// a [snapshot] after this returns, not before.
  Future<HerdrSubscription> subscribe(
    List<Subscription> subscriptions, {
    Duration? timeout,
  }) async {
    if (subscriptions.isEmpty) throw ArgumentError('no subscriptions');
    const method = 'events.subscribe';
    final (channel, lines, ack) = await _exchange(method, {
      'subscriptions': [for (final s in subscriptions) s.toJson()],
    }, timeout);
    try {
      _expectType(ack, 'subscription_started', method);
    } catch (_) {
      await lines.cancel();
      await channel.close();
      rethrow;
    }
    return HerdrSubscription._(channel, lines);
  }

  /// [request] plus a check of the result `type`.
  Future<Map<String, Object?>> _call(
    String method,
    String type, [
    Map<String, Object?> params = const {},
  ]) async => _expectType(await request(method, params), type, method);

  /// Dials, writes one request and reads its reply. On success the caller
  /// owns the open channel and line iterator; on failure both are released.
  Future<
    (HerdrChannel, StreamIterator<Map<String, Object?>>, Map<String, Object?>)
  >
  _exchange(
    String method,
    Map<String, Object?> params,
    Duration? timeout,
  ) async {
    final id = _nextId();
    final wait = timeout ?? this.timeout;
    final channel = await _open(method, wait);
    // A channel can fail with an error of the SSH library.
    final lines = StreamIterator(
      decodeNdjson(channel.input).handleError(
        (Object _) => throw HerdrConnectionClosedException(method),
        test: (e) => e is! HerdrException,
      ),
    );
    try {
      try {
        channel.write(
          encodeNdjson({'id': id, 'method': method, 'params': params}),
        );
      } on StateError {
        // The channel has just closed.
        throw HerdrConnectionClosedException(method);
      }
      return (channel, lines, _resultOf(await _next(lines, method, wait), id, method));
    } catch (_) {
      await lines.cancel();
      await channel.close();
      rethrow;
    }
  }

  Future<HerdrChannel> _open(String method, Duration wait) =>
      openChannel(_dial, wait, method);

  static Future<Map<String, Object?>> _next(
    StreamIterator<Map<String, Object?>> lines,
    String method,
    Duration wait,
  ) async {
    final bool hasLine;
    try {
      hasLine = await lines.moveNext().timeout(wait);
    } on TimeoutException {
      throw HerdrTimeoutException(method, wait);
    }
    if (!hasLine) throw HerdrConnectionClosedException(method);
    return lines.current;
  }

  static Map<String, Object?> _resultOf(
    Map<String, Object?> reply,
    String id,
    String method,
  ) {
    final error = reply['error'];
    if (error is Map<String, Object?>) {
      // herdr echoes our id on errors too; an empty id means it could not
      // read the request, which is still an answer to this request.
      final replyId = reply['id'];
      if (replyId != id && replyId != '') {
        throw HerdrProtocolException('$method: reply id "$replyId" != "$id"');
      }
      throw HerdrApiException.fromJson(method, error);
    }
    if (reply['id'] != id) {
      throw HerdrProtocolException('$method: reply id "${reply['id']}" != "$id"');
    }
    final result = reply['result'];
    if (result is! Map<String, Object?>) {
      throw HerdrProtocolException('$method: reply has no result object');
    }
    return result;
  }

  static Map<String, Object?> _expectType(
    Map<String, Object?> result,
    String type,
    String method,
  ) {
    if (result['type'] != type) {
      throw HerdrProtocolException(
        '$method: expected result type "$type", got "${result['type']}"',
      );
    }
    return result;
  }

  static Map<String, Object?> _field(
    Map<String, Object?> result,
    String key,
    String method,
  ) {
    final v = result[key];
    if (v is! Map<String, Object?>) {
      throw HerdrProtocolException('$method: result has no "$key" object');
    }
    return v;
  }
}

/// A live subscription. Listen to [events] once; cancel it or call [close]
/// to release the channel.
///
/// The stream ends when herdr closes the connection. On `events_lost` it
/// emits a [HerdrApiException] and ends: the caller's cache is stale and must
/// subscribe again and take a new snapshot.
class HerdrSubscription {
  HerdrSubscription._(this._channel, this._lines);

  final HerdrChannel _channel;
  final StreamIterator<Map<String, Object?>> _lines;
  var _closed = false;

  /// Single-subscription stream of pushed events.
  late final Stream<HerdrEvent> events = _events();

  Stream<HerdrEvent> _events() {
    // A StreamController instead of async*: an async* body cannot be
    // cancelled while it waits for the next line, so cancel would hang.
    final out = StreamController<HerdrEvent>(onCancel: close);
    out.onListen = () async {
      try {
        while (await _lines.moveNext()) {
          if (out.isClosed) return;
          final line = _lines.current;
          if (line['error'] case final Map<String, Object?> error) {
            throw HerdrApiException.fromJson('events.subscribe', error);
          }
          if (!line.containsKey('event')) {
            throw const HerdrProtocolException(
              'events.subscribe: unexpected line',
            );
          }
          out.add(HerdrEvent.fromJson(line));
        }
      } on HerdrException catch (e) {
        // Includes NdjsonFormatException, a HerdrProtocolException.
        if (!out.isClosed) out.addError(e);
      } finally {
        await close();
        if (!out.isClosed) await out.close();
      }
    };
    return out.stream;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _lines.cancel();
    await _channel.close();
  }
}

/// Dials a channel for [method] within [wait]. A dial that fails is a
/// [HerdrConnectException]; one that takes too long a
/// [HerdrTimeoutException].
Future<HerdrChannel> openChannel(
  HerdrDialer dial,
  Duration wait,
  String method,
) async {
  try {
    return await openWithin(dial(), wait, (c) => unawaited(c.close()), method);
  } on HerdrException {
    rethrow;
  } catch (e) {
    throw HerdrConnectException(method, e);
  }
}

/// Waits up to [timeout] for [open], else throws [HerdrTimeoutException]
/// with [method]. `Future.timeout` does not cancel the open, so a result
/// that arrives late goes to [discard] to release it.
Future<T> openWithin<T>(
  Future<T> open,
  Duration timeout,
  void Function(T late) discard,
  String method,
) async {
  try {
    return await open.timeout(timeout);
  } on TimeoutException {
    unawaited(open.then<void>(discard, onError: (Object _) {}));
    throw HerdrTimeoutException(method, timeout);
  }
}
