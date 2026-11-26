import 'dart:async';
import 'dart:convert';

import 'package:shellherd/herdr/transcript/transcript_stream.dart';

/// A [TranscriptOpener] whose reads the test drives: it hands out a
/// [FakeTranscriptChannel] per open and keeps them in [opened].
class FakeTranscripts {
  final opened = <FakeTranscriptChannel>[];

  /// When each read in [opened] opened.
  final openedAt = <DateTime>[];

  /// When set, the next open throws it.
  Object? failOpen;

  /// When set, opens wait for it.
  Completer<void>? holdOpen;

  FakeTranscriptChannel get last => opened.last;

  late final TranscriptOpener open = _open;

  Future<TranscriptChannel> _open(
    String session,
    TranscriptMark? from,
  ) async {
    if (failOpen case final error?) {
      failOpen = null;
      throw error;
    }
    await holdOpen?.future;
    final channel = FakeTranscriptChannel(session, from);
    opened.add(channel);
    openedAt.add(DateTime.now());
    return channel;
  }
}

/// One read: the test writes what the remote command prints.
class FakeTranscriptChannel implements TranscriptChannel {
  FakeTranscriptChannel(this.session, this.from);

  /// The Claude Code session whose transcript this reads.
  final String session;

  /// Where the stream asked the read to go on.
  final TranscriptMark? from;
  final _output = StreamController<List<int>>();
  var closed = false;

  @override
  Stream<List<int>> get output => _output.stream;

  @override
  void close() {
    closed = true;
    if (!_output.isClosed) unawaited(_output.close());
  }

  void bytes(List<int> data) {
    if (!_output.isClosed) _output.add(data);
  }

  void text(String data) => bytes(utf8.encode(data));

  /// The header for a file of [size] bytes with [inode] (`-`: no file),
  /// read from [start]: by default as the command starts a new read.
  void header(int size, {int? start, String inode = '1'}) {
    start ??= size > transcriptTail + 1 ? size - transcriptTail - 1 : 0;
    text('$transcriptHeader$size $start $inode\n');
  }

  /// A header for exactly [lines], then the lines: a whole small file.
  void file(List<String> lines) {
    final body = lines.map((l) => '$l\n').join();
    header(utf8.encode(body).length);
    text(body);
  }

  /// The read fails, as a non-zero exit does.
  void fail(Object error) {
    if (_output.isClosed) return;
    _output.addError(error);
    unawaited(_output.close());
  }
}

/// Lines of a Claude Code transcript, for tests.
String claudeUser(
  Object content, {
  String? uuid,
  Map<String, Object?> extra = const {},
}) => jsonEncode({
  'type': 'user',
  'uuid': ?uuid,
  'message': {'role': 'user', 'content': content},
  ...extra,
});

String claudeAssistant(
  List<Map<String, Object?>> blocks, {
  String id = 'msg_1',
  String? uuid,
  Map<String, Object?> extra = const {},
}) => jsonEncode({
  'type': 'assistant',
  'uuid': ?uuid,
  'message': {'id': id, 'role': 'assistant', 'content': blocks},
  ...extra,
});

Map<String, Object?> claudeText(String text) => {'type': 'text', 'text': text};

Map<String, Object?> claudeToolUse(
  String id,
  String name,
  Map<String, Object?> input,
) => {'type': 'tool_use', 'id': id, 'name': name, 'input': input};

Map<String, Object?> claudeToolResult(
  String id,
  Object content, {
  bool isError = false,
}) => {
  'type': 'tool_result',
  'tool_use_id': id,
  'content': content,
  'is_error': isError,
};
