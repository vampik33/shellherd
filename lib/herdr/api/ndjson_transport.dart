import 'dart:async';
import 'dart:convert';

import 'herdr_errors.dart';

/// One byte stream to a herdr API socket.
///
/// Locally this is a Unix socket; over SSH it is a
/// `direct-streamlocal@openssh.com` channel. herdr serves exactly one request
/// per connection (it closes the socket after the reply, and resets it if a
/// second line arrives), so every request dials a fresh channel. Event
/// subscriptions keep their channel open for pushed lines.
abstract interface class HerdrChannel {
  Stream<List<int>> get input;
  void write(List<int> bytes);
  Future<void> close();
}

/// Opens a new [HerdrChannel] to the same herdr server. It is called for
/// every request, so an SSH dialer must reuse one SSH connection and open
/// only a new channel each time.
typedef HerdrDialer = Future<HerdrChannel> Function();

/// A line from herdr is not a UTF-8 JSON object. It is a
/// [HerdrProtocolException], so client callers need no extra catch.
class NdjsonFormatException extends HerdrProtocolException {
  const NdjsonFormatException(super.message, [this.line]);
  final String? line;

  @override
  String toString() => 'NdjsonFormatException: $message'
      '${line == null ? '' : ' in line: $line'}';
}

/// Encodes one message as a single newline-terminated UTF-8 line.
List<int> encodeNdjson(Map<String, Object?> message) =>
    utf8.encode('${jsonEncode(message)}\n');

/// Splits [input] into lines and decodes each as a JSON object.
///
/// Chunk boundaries may fall anywhere, including inside a multi-byte UTF-8
/// sequence. Blank lines are skipped. Invalid UTF-8, invalid JSON or a
/// non-object value is reported as an [NdjsonFormatException] stream error.
///
/// Built from transformers, not `async*`: an `async*` body cannot be
/// cancelled while it waits for input, so a timed-out read could not
/// release its channel.
///
/// Sockets and SSH channels are `Stream<Uint8List>` at runtime even when
/// typed as `Stream<List<int>>`; the cast keeps `utf8.decoder` type-safe.
Stream<Map<String, Object?>> decodeNdjson(Stream<List<int>> input) => input
    .cast<List<int>>()
    .transform(utf8.decoder)
    .transform(const LineSplitter())
    .transform(
      StreamTransformer<String, Map<String, Object?>>.fromHandlers(
        handleData: (line, sink) {
          if (line.trim().isEmpty) return;
          final Object? value;
          try {
            value = jsonDecode(line);
          } on FormatException catch (e) {
            sink.addError(NdjsonFormatException('invalid JSON: ${e.message}', line));
            return;
          }
          if (value is Map<String, Object?>) {
            sink.add(value);
          } else {
            sink.addError(NdjsonFormatException('expected a JSON object', line));
          }
        },
        handleError: (error, stack, sink) => sink.addError(
          error is FormatException
              ? NdjsonFormatException('invalid UTF-8: ${error.message}')
              : error,
          stack,
        ),
      ),
    );
