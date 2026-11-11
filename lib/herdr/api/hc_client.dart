import 'dart:async';

import 'hc_models.dart';
import 'herdr_client.dart';
import 'json_fields.dart';

export 'hc_models.dart';

/// Client for the herdr-core (`hc`) JSON-RPC 2.0 API: the core of the
/// Herdr desktop app, which runs its terminals and agents.
///
/// Unlike herdr, herdr-core answers many requests on one connection, so
/// the quick ones share one channel and replies find their request by id.
/// But it answers them one at a time, and some wait long in the core:
/// input waits while a person types on the PC, and reading the history of
/// a full-screen program scrolls it. Those go on a channel of their own,
/// so they hold up nothing else. [subscribe] dials a channel of its own
/// too: after `events.subscribe` a connection carries only notifications.
///
/// Errors are the [HerdrException]s of [HerdrClient]. An error `kind` of
/// herdr-core that the app acts on becomes the herdr code for the same
/// thing (see [herdrCodeOf]), so callers handle both servers alike.
class HcClient {
  HcClient._(this._dial, this._rpc, this.timeout, this.hello);

  /// The protocol generation this client speaks.
  static const generation = 1;

  /// Dials the request channel and says `hello`. Throws a
  /// [HerdrConnectException] when the dial fails, and a
  /// [HerdrProtocolException] for a core of another generation.
  static Future<HcClient> connect(
    HerdrDialer dial, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    const method = 'hello';
    final rpc = _Rpc(await openChannel(dial, timeout, method));
    try {
      final hello = HcHello.fromJson(
        await rpc.call(method, {'generation': generation}, timeout),
      );
      if (hello.generation != generation) {
        throw HerdrProtocolException(
          'herdr-core speaks generation ${hello.generation}, '
          'this app $generation',
        );
      }
      return HcClient._(dial, rpc, timeout, hello);
    } catch (_) {
      await rpc.close();
      rethrow;
    }
  }

  final HerdrDialer _dial;
  final _Rpc _rpc;

  /// How long to wait for a channel to open, and for each reply.
  final Duration timeout;

  /// How long to wait for the reply to input. herdr-core holds a send up
  /// to 60 s after the last key of a person's unsent draft on the PC.
  static const inputTimeout = Duration(seconds: 75);

  /// Channels of single requests on their way.
  final _alone = <_Rpc>{};

  final HcHello hello;

  /// Completes when the request channel has ended.
  Future<void> get done => _rpc.done;

  /// Sends one raw request and returns its `result` object.
  Future<Map<String, Object?>> request(
    String method, [
    Map<String, Object?> params = const {},
  ]) => _rpc.call(method, params, timeout);

  /// Live terminals.
  Future<List<HcTerminal>> terminals() async {
    const method = 'terminal.list';
    final r = await _rpc.call(method, const {}, timeout);
    return jsonList(r, 'terminals', HcTerminal.fromJson);
  }

  /// [terminal] as the core sees it now.
  Future<HcTerminal> terminal(String terminal) async => HcTerminal.fromJson(
    await _rpc.call('terminal.get', {'terminal': terminal}, timeout),
  );

  /// Sets [labels] of [terminal]; others stay.
  Future<void> label(String terminal, Map<String, String> labels) async {
    await _rpc.call('terminal.label', {
      'terminal': terminal,
      'labels': labels,
    }, timeout);
  }

  /// The layout of the Herdr app.
  Future<HcLayout> layout() async {
    final r = await _rpc.call('doc.get', {'name': HcLayout.document}, timeout);
    return HcLayout.fromJson(r['value']);
  }

  /// The screen of [terminal] plus [lines] of history, as plain text.
  Future<String> read(String terminal, {required int lines}) async {
    final r = await _callAlone('terminal.read', {
      'terminal': terminal,
      'lines': lines,
    }, timeout);
    return jsonField<String>(r, 'text');
  }

  /// Presses key names such as `esc`, `enter`, `ctrl+c` or `a`, once a
  /// person on the PC has stopped typing for a moment.
  Future<void> keys(String terminal, List<String> keys) async {
    if (keys.isEmpty) throw ArgumentError('keys needs keys');
    await _callAlone('terminal.keys', {
      'terminal': terminal,
      'keys': keys,
    }, inputTimeout);
  }

  /// Pastes [text] and presses Enter. herdr-core refuses a blocked program,
  /// and holds the text while a person on the PC has an unsent draft.
  Future<void> send(String terminal, String text) async {
    await _callAlone('terminal.send', {
      'terminal': terminal,
      'text': text,
    }, inputTimeout);
  }

  /// Sends one request on a channel of its own, and closes the channel
  /// after the reply or the timeout. Closing it also calls back input that
  /// herdr-core still holds. herdr-core needs no `hello` first.
  Future<Map<String, Object?>> _callAlone(
    String method,
    Map<String, Object?> params,
    Duration wait,
  ) async {
    final rpc = _Rpc(await openChannel(_dial, timeout, method));
    _alone.add(rpc);
    try {
      if (_rpc.ended) throw HerdrConnectionClosedException(method);
      return await rpc.call(method, params, wait);
    } finally {
      _alone.remove(rpc);
      // The reply is in; the close need not hold it up.
      unawaited(rpc.close());
    }
  }

  /// Opens a subscription to every change of every terminal and of the
  /// documents. Returns after herdr-core acknowledges it; changes after
  /// that come as notifications.
  Future<HcSubscription> subscribe() async {
    const method = 'events.subscribe';
    final rpc = _Rpc(await openChannel(_dial, timeout, method));
    try {
      await rpc.call(method, const {}, timeout);
    } catch (_) {
      await rpc.close();
      rethrow;
    }
    return HcSubscription._(rpc);
  }

  /// Closes the request channel and the channels of single requests,
  /// which fail as closed.
  Future<void> close() => Future.wait([
    _rpc.close(),
    for (final rpc in [..._alone]) rpc.close(),
  ]);
}

/// A live subscription. [notes] ends when the connection ends, with an
/// error first if the connection failed.
class HcSubscription {
  HcSubscription._(this._rpc);

  final _Rpc _rpc;

  /// The method of each notification: `event` (a fact changed),
  /// `heartbeat` (every 15 s) or `missed` (this subscriber fell behind).
  /// Single-subscription.
  Stream<String> get notes => _rpc.notes;

  Future<void> close() => _rpc.close();
}

/// The herdr code for an error `kind` of herdr-core, where the app tells
/// the two apart: a terminal that is gone, and a blocked program.
String herdrCodeOf(String kind) => switch (kind) {
  'not_found' || 'finished' => 'pane_not_found',
  'blocked' => 'agent_blocked',
  _ => kind,
};

/// JSON-RPC over one channel: requests matched to replies by id, and
/// notifications on [notes].
class _Rpc {
  _Rpc(this._channel) {
    _lines = decodeNdjson(_channel.input)
        .listen(_onLine, onError: _onError, onDone: () => _end(null));
  }

  final HerdrChannel _channel;
  late final StreamSubscription<Map<String, Object?>> _lines;
  final _pending = <int, (String, Completer<Map<String, Object?>>)>{};
  final _notes = StreamController<String>();
  final _done = Completer<void>();
  var _seq = 0;

  Stream<String> get notes => _notes.stream;

  Future<void> get done => _done.future;

  bool get ended => _done.isCompleted;

  Future<Map<String, Object?>> call(
    String method,
    Map<String, Object?> params,
    Duration timeout,
  ) {
    if (ended) {
      return Future.error(HerdrConnectionClosedException(method));
    }
    final id = ++_seq;
    final reply = Completer<Map<String, Object?>>();
    _pending[id] = (method, reply);
    try {
      _channel.write(
        encodeNdjson({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': params,
        }),
      );
    } on StateError {
      // The channel has just closed.
      _pending.remove(id);
      return Future.error(HerdrConnectionClosedException(method));
    }
    return reply.future.timeout(
      timeout,
      onTimeout: () {
        // A reply that comes later finds no request and is dropped.
        _pending.remove(id);
        throw HerdrTimeoutException(method, timeout);
      },
    );
  }

  void _onLine(Map<String, Object?> line) {
    final id = line['id'];
    if (id == null) {
      if (line['method'] case final String method) {
        if (!_notes.isClosed) _notes.add(method);
      } else {
        _end(const HerdrProtocolException('a line with no id and no method'));
      }
      return;
    }
    final pending = _pending.remove(id);
    if (pending == null) return;
    final (method, reply) = pending;
    switch ((line['error'], line['result'])) {
      case (final Map<String, Object?> error, _):
        reply.completeError(_apiException(method, error));
      case (_, final Map<String, Object?> result):
        reply.complete(result);
      default:
        reply.completeError(
          HerdrProtocolException('$method: reply has no result object'),
        );
    }
  }

  /// `{"code": -32602, "message": "...", "data": {"kind": "invalid_params"}}`.
  static HerdrApiException _apiException(
    String method,
    Map<String, Object?> error,
  ) {
    final data = error['data'];
    final kind = data is Map<String, Object?> ? data['kind'] : null;
    return HerdrApiException(
      method,
      herdrCodeOf(kind is String ? kind : 'unknown'),
      error['message'] is String ? error['message']! as String : '',
    );
  }

  /// A line that is not JSON is the server's fault; any other error comes
  /// from the channel, for example the SSH library.
  void _onError(Object e) => _end(e is HerdrException ? e : null);

  /// Fails what is still waiting and ends [notes]: with [error], or as a
  /// closed connection.
  void _end(HerdrException? error) {
    if (_done.isCompleted) return;
    _done.complete();
    for (final (method, reply) in _pending.values) {
      reply.completeError(error ?? HerdrConnectionClosedException(method));
    }
    _pending.clear();
    if (error != null && !_notes.isClosed) _notes.addError(error);
    unawaited(_notes.close());
    unawaited(_lines.cancel());
    unawaited(_closeChannel());
  }

  Future<void>? _channelClosed;

  Future<void> _closeChannel() => _channelClosed ??= _channel.close();

  Future<void> close() {
    _end(null);
    return _closeChannel();
  }
}
