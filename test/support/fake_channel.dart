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

  /// While set, a write throws it.
  Object? writeError;

  @override
  Stream<List<int>> get input => _input.stream;

  @override
  void write(List<int> bytes) {
    if (writeError case final error?) throw error;
    final msg = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    sent.add(msg);
    if (!_firstWrite.isCompleted) _firstWrite.complete(msg);
  }

  @override
  Future<void> close() async {
    closed = true;
    end();
  }

  /// The first request the client wrote.
  Future<Map<String, Object?>> get request => _firstWrite.future;

  void reply(Map<String, Object?> msg) => replyRaw(encodeNdjson(msg));

  void replyRaw(List<int> bytes) {
    if (!_input.isClosed) _input.add(bytes);
  }

  /// The channel fails with [error], which is not from herdr.
  void fail(Object error) => _input.addError(error);

  /// The server closes the connection. Not awaited: a controller's close()
  /// completes only once a listener sees "done".
  void end() {
    if (!_input.isClosed) unawaited(_input.close());
  }
}

/// Hands out a fresh [FakeChannel] per dial and records each one.
class FakeDialer {
  final channels = <FakeChannel>[];
  final _dialed = StreamController<FakeChannel>.broadcast();
  Object? failWith;

  /// Passed on to [FakeChannel.writeError] of each new channel.
  Object? writeError;

  Future<HerdrChannel> call() async {
    if (failWith != null) throw failWith!;
    final c = FakeChannel()..writeError = writeError;
    channels.add(c);
    _dialed.add(c);
    return c;
  }

  /// Every channel the client dials, from now on.
  Stream<FakeChannel> get dialed => _dialed.stream;

  /// Completes with the next channel the client dials.
  Future<FakeChannel> get next => _dialed.stream.first;
}
