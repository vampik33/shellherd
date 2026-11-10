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

  /// Default time to wait for a reply, counted after the channel is open.
  final Duration timeout;

  var _seq = 0;

  String _nextId() => '$idPrefix-${++_seq}';

  /// Sends one raw request and returns its `result` object.
  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?> params = const {},
    Duration? timeout,
  ]) async {
    final id = _nextId();
    final wait = timeout ?? this.timeout;
    final channel = await _open(method);
    final replies = StreamIterator(decodeNdjson(channel.input));
    try {
      channel.write(encodeNdjson(_envelope(id, method, params)));
      return _resultOf(await _next(replies, method, wait), id, method);
    } finally {
      await replies.cancel();
      await channel.close();
    }
  }

  Future<HerdrPing> ping() async {
    final r = await request('ping');
    return HerdrPing.fromJson(_expectType(r, 'pong', 'ping'));
  }

  Future<HerdrSnapshot> snapshot() async {
    final r = _expectType(
      await request('session.snapshot'),
      'session_snapshot',
      'session.snapshot',
    );
    return HerdrSnapshot.fromJson(_field(r, 'snapshot', 'session.snapshot'));
  }

  /// Reads pane text. With [ReadFormat.ansi] the escape sequences are kept.
  Future<PaneRead> paneRead(
    String paneId, {
    ReadSource source = ReadSource.recentUnwrapped,
    ReadFormat format = ReadFormat.text,
    int? lines,
  }) async {
    final r = _expectType(
      await request('pane.read', {
        'pane_id': paneId,
        'source': source.wire,
        'format': format.name,
        'lines': ?lines,
        if (format == ReadFormat.ansi) 'strip_ansi': false,
      }),
      'pane_read',
      'pane.read',
    );
    return PaneRead.fromJson(_field(r, 'read', 'pane.read'));
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
    _expectType(
      await request('pane.send_input', {
        'pane_id': paneId,
        'text': ?text,
        if (keys.isNotEmpty) 'keys': keys,
      }),
      'ok',
      'pane.send_input',
    );
  }

  /// Sends herdr key names: `esc`, `enter`, `ctrl+c`, `up`, `f1`, ...
  Future<void> paneSendKeys(String paneId, List<String> keys) async {
    if (keys.isEmpty) throw ArgumentError('paneSendKeys needs keys');
    _expectType(
      await request('pane.send_keys', {'pane_id': paneId, 'keys': keys}),
      'ok',
      'pane.send_keys',
    );
  }

  /// Submits [text] plus Enter to the agent in [target] (a pane id or a live
  /// agent name). herdr rejects a blocked agent with `agent_blocked`.
  Future<void> agentPrompt(String target, String text) async {
    _expectType(
      await request('agent.prompt', {'target': target, 'text': text}),
      'agent_prompted',
      'agent.prompt',
    );
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
    final id = _nextId();
    final channel = await _open(method);
    final lines = StreamIterator(decodeNdjson(channel.input));
    try {
      channel.write(
        encodeNdjson(
          _envelope(id, method, {
            'subscriptions': [for (final s in subscriptions) s.toJson()],
          }),
        ),
      );
      final ack = _resultOf(
        await _next(lines, method, timeout ?? this.timeout),
        id,
        method,
      );
      _expectType(ack, 'subscription_started', method);
    } catch (_) {
      await lines.cancel();
      await channel.close();
      rethrow;
    }
    return HerdrSubscription._(channel, lines);
  }

  Future<HerdrChannel> _open(String method) async {
    try {
      return await _dial();
    } on HerdrException {
      rethrow;
    } catch (e) {
      throw HerdrConnectException(method, e);
    }
  }

  static Map<String, Object?> _envelope(
    String id,
    String method,
    Map<String, Object?> params,
  ) => {'id': id, 'method': method, 'params': params};

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
    } on NdjsonFormatException catch (e) {
      throw HerdrProtocolException('$method: ${e.message}');
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
      throw HerdrApiException(
        method,
        error['code'] is String ? error['code']! as String : 'unknown',
        error['message'] is String ? error['message']! as String : '',
      );
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
          if (line.containsKey('event')) {
            out.add(HerdrEvent.fromJson(line));
          } else if (line['error'] case final Map<String, Object?> error) {
            out.addError(
              HerdrApiException(
                'events.subscribe',
                error['code'] is String ? error['code']! as String : 'unknown',
                error['message'] is String ? error['message']! as String : '',
              ),
            );
            return;
          } else {
            throw const HerdrProtocolException(
              'events.subscribe: unexpected line',
            );
          }
        }
      } on NdjsonFormatException catch (e) {
        if (!out.isClosed) {
          out.addError(HerdrProtocolException('events.subscribe: ${e.message}'));
        }
      } on HerdrException catch (e) {
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
