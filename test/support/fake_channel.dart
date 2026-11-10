import 'dart:async';
import 'dart:convert';

import 'package:shellherd/herdr/api/herdr_client.dart';

/// In-memory [HerdrChannel]. The test plays the server through [reply],
/// [replyRaw] and [end], and reads what the client sent from [sent].
class FakeChannel implements HerdrChannel {
  final _input = StreamController<List<int>>();
  final sent = <Map<String, Object?>>[];
  final _firstWrite = Completer<Map<String, Object?>>();
  var closed = false;

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  void write(List<int> bytes) {
    final msg = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    sent.add(msg);
    if (!_firstWrite.isCompleted) _firstWrite.complete(msg);
  }

  @override
  Future<void> close() async {
    closed = true;
    // Not awaited: close() only completes once a listener sees "done".
    if (!_input.isClosed) unawaited(_input.close());
  }

  /// The first request the client wrote.
  Future<Map<String, Object?>> get request => _firstWrite.future;

  void reply(Map<String, Object?> msg) => replyRaw(utf8.encode('${jsonEncode(msg)}\n'));

  void replyRaw(List<int> bytes) {
    if (!_input.isClosed) _input.add(bytes);
  }

  /// The server closes the connection.
  Future<void> end() async {
    if (!_input.isClosed) unawaited(_input.close());
  }
}

/// Hands out a fresh [FakeChannel] per dial and records each one.
class FakeDialer {
  final channels = <FakeChannel>[];
  final _dialed = StreamController<FakeChannel>.broadcast();
  Object? failWith;

  Future<HerdrChannel> call() async {
    if (failWith != null) throw failWith!;
    final c = FakeChannel();
    channels.add(c);
    _dialed.add(c);
    return c;
  }

  /// Completes with the next channel the client dials.
  Future<FakeChannel> get next => _dialed.stream.first;
}
