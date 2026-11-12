import 'dart:async';
import 'dart:convert';

import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/pane_stream.dart';

/// A [ScreenOpener] whose observers the test drives: it hands out a
/// [FakeScreenChannel] per open and keeps them in [opened].
class FakeScreens {
  final opened = <FakeScreenChannel>[];

  /// When set, the next open throws it.
  Object? failOpen;

  /// When set, opens wait for it.
  Completer<void>? holdOpen;

  FakeScreenChannel get last => opened.last;

  late final ScreenOpener open = _open;

  Future<ScreenChannel> _open(String paneId, PaneSize size) async {
    if (failOpen case final error?) {
      failOpen = null;
      throw error;
    }
    await holdOpen?.future;
    final channel = FakeScreenChannel(paneId, size);
    opened.add(channel);
    return channel;
  }
}

/// One observer: the test writes its records, [PaneStream] reads them.
class FakeScreenChannel implements ScreenChannel {
  FakeScreenChannel(this.paneId, this.size);

  final String paneId;
  final PaneSize size;
  final _output = StreamController<List<int>>();
  var closed = false;

  @override
  Stream<List<int>> get output => _output.stream;

  @override
  void close() {
    closed = true;
    if (!_output.isClosed) unawaited(_output.close());
  }

  void line(String text) {
    if (!_output.isClosed) _output.add(utf8.encode('$text\n'));
  }

  /// A frame with [ansi] as its terminal bytes.
  void frame(String ansi, {bool full = false}) => line(
    jsonEncode({
      'type': 'terminal.frame',
      'seq': 1,
      'encoding': 'ansi',
      'width': size.cols,
      'height': size.rows,
      'full': full,
      'bytes': base64Encode(utf8.encode(ansi)),
    }),
  );

  void closedRecord(String? reason) =>
      line(jsonEncode({'type': 'terminal.closed', 'reason': reason}));

  /// The observer exits.
  void end() => close();

  /// The observer fails, as a non-zero exit does.
  void fail(Object error) {
    if (_output.isClosed) return;
    _output.addError(error);
    unawaited(_output.close());
  }
}
