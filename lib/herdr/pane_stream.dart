import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../ssh/ssh_exec.dart';
import 'api/herdr_client.dart';
import 'api/json_fields.dart';
import 'pane_poller.dart';

/// One running `herdr terminal session observe`: its output is one JSON
/// record per line.
typedef ScreenChannel = ExecChannel;

/// Starts an observer of [paneId] that draws it at [size].
typedef ScreenOpener =
    Future<ScreenChannel> Function(String paneId, PaneSize size);

/// A record of `terminal session observe`.
sealed class ScreenRecord {
  const ScreenRecord();

  /// The record on [line]; null for a line that is no record, such as text
  /// from the remote shell's startup files, or a type this build does not
  /// know. Throws [HerdrProtocolException] for a record it cannot read.
  static ScreenRecord? parse(String line) {
    if (!line.startsWith('{')) return null;
    final Object? json;
    try {
      json = jsonDecode(line);
    } on FormatException {
      return null;
    }
    if (json is! Map<String, Object?>) return null;
    return switch (json['type']) {
      'terminal.frame' => ScreenFrame(
        cols: jsonField<int>(json, 'width'),
        rows: jsonField<int>(json, 'height'),
        bytes: _base64(jsonField<String>(json, 'bytes')),
      ),
      'terminal.closed' => ScreenClosed(jsonOptional<String>(json, 'reason')),
      _ => null,
    };
  }

  static List<int> _base64(String text) {
    try {
      return base64Decode(text);
    } on FormatException catch (e) {
      throw HerdrProtocolException('terminal.frame bytes: $e');
    }
  }
}

/// Terminal output that brings the drawn screen up to date: all of it in
/// the first frame, then the changes.
class ScreenFrame extends ScreenRecord {
  const ScreenFrame({
    required this.cols,
    required this.rows,
    required this.bytes,
  });

  final int cols;
  final int rows;
  final List<int> bytes;
}

/// herdr ended the stream, for example because the pane closed.
class ScreenClosed extends ScreenRecord {
  const ScreenClosed(this.reason);
  final String? reason;

  /// herdr no longer has the pane: "terminal target … not found" before
  /// the stream started, "terminal … not found" after.
  bool get paneGone => reason?.contains('not found') ?? false;
}

/// The screen of one pane as herdr draws it, pushed by an observer instead
/// of read again and again: [PanePoller] waits at least a poll interval and
/// reads the whole text each time, the stream sends the changes as they
/// happen.
///
/// It draws the pane at its size in [size], because an observer shows only
/// the cells that fit, from the top left. A new size starts a new
/// observer.
///
/// When an observer fails before its first frame, for example because the
/// remote host has no `herdr terminal session`, [unavailable] turns true
/// and stays so until the next link: the screen reads with [PanePoller]
/// then. An observer that ends after frames came, because the link
/// stalled or herdr restarted, starts again after [retryDelay].
class PaneStream {
  PaneStream(
    this._opener,
    this.paneId,
    this._size, {
    required this.changes,
    this.openTimeout = const Duration(seconds: 15),
    this.retryDelay = const Duration(seconds: 1),
  }) {
    changes.addListener(_follow);
    _lastOpener = _opener();
  }

  /// The opener of the current link; null without one.
  final ScreenOpener? Function() _opener;

  /// The size of the pane; null while it is not known.
  final PaneSize? Function() _size;

  /// When the opener or the size can have changed.
  final Listenable changes;

  final String paneId;

  /// The longest wait for an observer to start and send its first frame.
  final Duration openTimeout;

  final Duration retryDelay;

  /// The screen. Its text is null until the first frame.
  final view = ValueNotifier(const PaneView());

  /// True after an observer of the current link failed before its first
  /// frame.
  final unavailable = ValueNotifier(false);

  /// Why the observer failed, while [unavailable]: the first line of the
  /// error, for the user.
  String? get whyUnavailable => _why;
  String? _why;

  final _terminal = Terminal(reflowEnabled: false);

  ScreenOpener? _lastOpener;

  /// Bumped when an observer must stop; a run that sees another number is
  /// over.
  var _run = 0;

  /// The size of the running observer; null when none runs.
  PaneSize? _runSize;
  ScreenChannel? _channel;
  Timer? _retry;

  /// Draws the frames that came in one turn of the event loop at once:
  /// several often arrive in one read.
  Timer? _publish;
  var _running = false;
  var _closed = false;

  /// Whether an observer should run: while the pane is on the screen and
  /// the stream is what it shows.
  set running(bool value) {
    if (value == _running) return;
    _running = value;
    value ? _start() : _stop();
  }

  void dispose() {
    _closed = true;
    changes.removeListener(_follow);
    _stop();
    view.dispose();
    unavailable.dispose();
  }

  void _follow() {
    if (_closed) return;
    final opener = _opener();
    final size = _size();
    if (opener != _lastOpener) {
      _lastOpener = opener;
      _why = null;
      unavailable.value = false;
      _stop();
    } else if (_runSize != null && size != null && size != _runSize) {
      _stop();
    }
    _start();
  }

  void _stop() {
    _run++;
    _retry?.cancel();
    _retry = null;
    // The next observer clears the screen; a late draw would show that.
    _publish?.cancel();
    _publish = null;
    _release();
  }

  void _release() {
    _channel?.close();
    _channel = null;
    _runSize = null;
  }

  void _draw() {
    _publish = null;
    final text = screenText(_terminal);
    if (text != view.value.text) view.value = PaneView(text: text);
  }

  /// Whether an observer can start: the link has an opener, the pane a
  /// size, and the stream is not [unavailable].
  bool get canObserve =>
      !unavailable.value && _opener() != null && _size() != null;

  void _start() {
    if (!_running || _closed || view.value.gone || !canObserve) return;
    if (_runSize != null || _retry != null) return;
    final opener = _opener()!;
    final size = _size()!;
    _runSize = size;
    unawaited(_observe(opener, size, ++_run));
  }

  Future<void> _observe(ScreenOpener opener, PaneSize size, int run) async {
    bool current() => run == _run && !_closed;
    var frames = 0;
    ScreenClosed? closed;
    Object? failure;
    Timer? firstFrame;
    try {
      final channel = await openWithin(
        opener(paneId, size),
        openTimeout,
        (late) => late.close(),
        'terminal session observe',
      );
      if (!current()) {
        channel.close();
        return;
      }
      _channel = channel;
      firstFrame = Timer(openTimeout, () {
        if (frames == 0) channel.close();
      });
      // herdr's first frame draws all of the screen; a clean one also
      // drops the styles and modes the last observer left.
      _terminal
        ..resize(size.cols, size.rows)
        ..write('\x1b[0m\x1b[2J\x1b[H');
      final lines = channel.output
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        if (!current()) return;
        switch (ScreenRecord.parse(line)) {
          case ScreenFrame(:final bytes):
            frames++;
            _terminal.write(utf8.decode(bytes, allowMalformed: true));
            _publish ??= Timer(Duration.zero, _draw);
          case final ScreenClosed c:
            closed = c;
          case null:
            break;
        }
        if (closed != null) break;
      }
    } catch (e) {
      failure = e;
    } finally {
      firstFrame?.cancel();
      if (run == _run) _release();
    }
    if (!current()) return;
    if (closed?.paneGone ?? false) {
      if (_publish != null) {
        _publish!.cancel();
        _draw();
      }
      view.value = PaneView(text: view.value.text, gone: true);
      return;
    }
    if (frames == 0) {
      final why = '${failure ?? closed?.reason ?? 'no first frame'}';
      debugPrint('shellherd: no screen stream for $paneId, reading it instead: $why');
      _why = why.trim().split('\n').first;
      unavailable.value = true;
      return;
    }
    _retry = Timer(retryDelay, () {
      _retry = null;
      _start();
    });
  }
}

/// The visible screen of [terminal] as text with colour and style
/// sequences (SGR), one line per row with every cell, for [parseAnsi].
String screenText(Terminal terminal) {
  final buffer = terminal.buffer;
  final out = StringBuffer();
  var style = '';
  // Cells in a row mostly share their colours and flags.
  int? fg, bg, attrs;
  for (var y = 0; y < terminal.viewHeight; y++) {
    if (y > 0) out.write('\n');
    final line = buffer.lines[buffer.scrollBack + y];
    for (var x = 0; x < terminal.viewWidth && x < line.length; x++) {
      final width = line.getWidth(x);
      final code = line.getCodePoint(x);
      // The second cell of a wide character.
      if (width == 0 && code == 0 && x > 0 && line.getWidth(x - 1) == 2) {
        continue;
      }
      final (cellFg, cellBg, cellAttrs) = (
        line.getForeground(x),
        line.getBackground(x),
        line.getAttributes(x),
      );
      if (cellFg != fg || cellBg != bg || cellAttrs != attrs) {
        (fg, bg, attrs) = (cellFg, cellBg, cellAttrs);
        final cellStyle = _sgr(cellFg, cellBg, cellAttrs);
        if (cellStyle != style) {
          out.write('\x1b[${cellStyle.isEmpty ? '0' : '0;$cellStyle'}m');
          style = cellStyle;
        }
      }
      final hidden = cellAttrs & CellAttr.invisible != 0;
      out.write(code == 0 || hidden ? ' ' : String.fromCharCode(code));
    }
  }
  if (style.isNotEmpty) out.write('\x1b[0m');
  return out.toString();
}

/// The SGR parameters, after a reset, for one cell's colours and flags.
String _sgr(int fg, int bg, int attrs) {
  final codes = [
    if (attrs & CellAttr.bold != 0) '1',
    if (attrs & CellAttr.faint != 0) '2',
    if (attrs & CellAttr.italic != 0) '3',
    if (attrs & CellAttr.underline != 0) '4',
    if (attrs & CellAttr.inverse != 0) '7',
    if (attrs & CellAttr.strikethrough != 0) '9',
    ?_color(fg, foreground: true),
    ?_color(bg, foreground: false),
  ];
  return codes.join(';');
}

String? _color(int color, {required bool foreground}) {
  final value = color & CellColor.valueMask;
  return switch (color & CellColor.typeMask) {
    CellColor.named when value < 8 => '${(foreground ? 30 : 40) + value}',
    CellColor.named => '${(foreground ? 90 : 100) + value - 8}',
    CellColor.palette => '${foreground ? 38 : 48};5;$value',
    CellColor.rgb =>
      '${foreground ? 38 : 48};2;'
          '${value >> 16 & 0xff};${value >> 8 & 0xff};${value & 0xff}',
    _ => null,
  };
}
