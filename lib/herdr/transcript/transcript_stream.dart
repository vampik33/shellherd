import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../ssh/ssh_exec.dart';
import '../api/herdr_client.dart';
import 'chat_items.dart';
import 'claude_transcript.dart';

/// One running read of a transcript: its output is the header line, then
/// the end of the file and each line added to it.
typedef TranscriptChannel = ExecChannel;

/// Starts a read of the transcript of Claude Code session [session] on the
/// remote host.
typedef TranscriptOpener = Future<TranscriptChannel> Function(String session);

/// How much of the end of a transcript a read starts with, past the line
/// the cut falls in. Transcripts grow to hundreds of megabytes.
const transcriptTail = 2 * 1024 * 1024;

/// The first line of a read: the marker and the size of the file. Lines
/// before it come from the remote shell's startup files.
const transcriptHeader = 'shellherd-transcript ';

/// The size in a header line; null for any other line. A startup file
/// can print text without a newline: it then stands before the marker.
int? transcriptSize(String line) {
  final at = line.indexOf(transcriptHeader);
  return at < 0
      ? null
      : int.tryParse(line.substring(at + transcriptHeader.length).trim());
}

/// The wait before the next read after [failures] reads in a row that
/// brought nothing new: [first], doubled for each failure after the
/// first, up to [most].
Duration retryWait(int failures, Duration first, Duration most) {
  if (failures <= 1) return first;
  final wait = first * (1 << min(failures - 1, 20));
  return wait > most ? most : wait;
}

/// The longest transcript line that is kept, in bytes, without its
/// newline. A longer one, such as a record with a large inline image, is
/// dropped: the phone would hold it several times over.
const maxTranscriptLine = 8 * 1024 * 1024;

/// A line that [ByteLines] split off: its bytes without the newline, null
/// for a line that was dropped, and how many bytes it took with the
/// newline.
typedef ByteLine = ({List<int>? bytes, int size});

/// Splits bytes into lines at each newline, keeping a line's bytes until it
/// ends, so that a reader knows how many bytes each line took. A line
/// longer than [maxLine] is dropped through its newline.
class ByteLines {
  ByteLines({this.maxLine = maxTranscriptLine});

  final int maxLine;

  /// One byte per byte; a list of ints would take eight.
  final _partial = BytesBuilder(copy: false);

  /// The bytes so far of a line being dropped; null while none is.
  int? _dropped;

  /// The bytes of the line that has not ended yet, kept or dropped.
  int get pending => _dropped ?? _partial.length;

  /// The lines that [chunk] completes.
  List<ByteLine> add(List<int> chunk) {
    final lines = <ByteLine>[];
    var from = 0;
    for (var i = 0; i < chunk.length; i++) {
      if (chunk[i] != 0x0a) continue;
      _take(chunk, from, i);
      lines.add(
        _dropped == null
            ? (size: _partial.length + 1, bytes: _partial.takeBytes())
            : (bytes: null, size: _dropped! + 1),
      );
      _partial.clear();
      _dropped = null;
      from = i + 1;
    }
    _take(chunk, from, chunk.length);
    return lines;
  }

  void _take(List<int> chunk, int from, int to) {
    final dropped = _dropped;
    if (dropped != null) {
      _dropped = dropped + to - from;
    } else if (_partial.length + to - from > maxLine) {
      _dropped = _partial.length + to - from;
      _partial.clear();
    } else {
      if (to > from) _partial.add(chunk.sublist(from, to));
    }
  }
}

/// What the app knows of a transcript.
class TranscriptView {
  const TranscriptView({this.items, this.startsCut = false});

  /// Oldest first; null until a read started.
  final List<ChatItem>? items;

  /// The read began after the start of the file: older messages are not
  /// shown.
  final bool startsCut;
}

/// The conversation of the Claude Code session in one pane, read from its
/// transcript: the last [transcriptTail] bytes first, then each record as
/// Claude Code adds it.
///
/// A new opener (a new link) or a new session (after `/clear`) starts a
/// new read. When a read fails before its header, for example because the
/// transcript cannot be found, [unavailable] turns true and stays so until
/// the next link or session: the pane shows its text then. A read that
/// ends after its header, because the link stalled, starts again after
/// [retryDelay], doubled for each read in a row that brought nothing new,
/// up to [maxRetryDelay].
class TranscriptStream {
  TranscriptStream(
    this._opener,
    this._session, {
    required this.changes,
    this.openTimeout = const Duration(seconds: 15),
    this.retryDelay = const Duration(seconds: 1),
    this.maxRetryDelay = const Duration(seconds: 30),
  }) {
    changes.addListener(_follow);
    _lastOpener = _opener();
    _lastSession = _session();
  }

  /// The opener of the current link; null without one.
  final TranscriptOpener? Function() _opener;

  /// The Claude Code session of the pane; null while it has none.
  final String? Function() _session;

  /// When the opener or the session can have changed.
  final Listenable changes;

  /// The longest wait for a read to start and send its header.
  final Duration openTimeout;

  final Duration retryDelay;
  final Duration maxRetryDelay;

  final view = ValueNotifier(const TranscriptView());

  /// True after a read of the current link and session failed before its
  /// header.
  final unavailable = ValueNotifier(false);

  /// Why the read failed, while [unavailable]: the first line of the
  /// error, for the user.
  String? get whyUnavailable => _why;
  String? _why;

  TranscriptOpener? _lastOpener;
  String? _lastSession;

  /// Reads in a row that ended without bringing anything new.
  var _failures = 0;

  /// Bumped when a read must stop; a run that sees another number is over.
  var _run = 0;
  var _reading = false;
  TranscriptChannel? _channel;
  Timer? _retry;

  /// Shows the records that came in one turn of the event loop at once.
  Timer? _publish;
  var _running = false;
  var _closed = false;

  /// Whether a read should run: while the chat is on the screen.
  set running(bool value) {
    if (value == _running) return;
    _running = value;
    value ? _start() : _stop();
  }

  /// Whether a read can start: the link has an opener, the pane a
  /// session, and the read is not [unavailable].
  bool get canRead =>
      !unavailable.value && _opener() != null && _session() != null;

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
    final session = _session();
    if (session != _lastSession) {
      _lastSession = session;
      // Another conversation: the old one must not stay on the screen.
      view.value = const TranscriptView();
      _reset();
    } else if (opener != _lastOpener) {
      _reset();
    }
    _lastOpener = opener;
    _start();
  }

  void _reset() {
    // Stopped first: clearing [unavailable] can start a read at once.
    _stop();
    _why = null;
    _failures = 0;
    unavailable.value = false;
  }

  void _stop() {
    _run++;
    _retry?.cancel();
    _retry = null;
    _publish?.cancel();
    _publish = null;
    _release();
  }

  void _release() {
    _channel?.close();
    _channel = null;
    _reading = false;
  }

  void _start() {
    if (!_running || _closed || !canRead) return;
    if (_reading || _retry != null) return;
    _reading = true;
    unawaited(_read(_opener()!, _session()!, ++_run));
  }

  Future<void> _read(TranscriptOpener opener, String session, int run) async {
    bool current() => run == _run && !_closed;
    final transcript = ClaudeTranscript();
    var header = false;
    var startsCut = false;
    // The bytes of the file's end that the read starts with, and how many
    // of them came: the chat shows once all did, so that a new read does
    // not show half of what the last one showed.
    var initial = 0;
    var received = 0;
    Object? failure;
    Timer? firstLine;
    void publish() {
      _publish = null;
      view.value = TranscriptView(
        items: transcript.items,
        startsCut: startsCut,
      );
    }

    try {
      final channel = await openWithin(
        opener(session),
        openTimeout,
        (late) => late.close(),
        'transcript read',
      );
      if (!current()) {
        channel.close();
        return;
      }
      _channel = channel;
      firstLine = Timer(openTimeout, () {
        if (!header) channel.close();
      });
      final splitter = ByteLines();
      await for (final chunk in channel.output) {
        if (!current()) return;
        for (final (:bytes, size: length) in splitter.add(chunk)) {
          final line = bytes == null
              ? null
              : utf8.decode(bytes, allowMalformed: true);
          if (!header) {
            if (line == null) continue;
            final size = transcriptSize(line);
            if (size == null) continue;
            header = true;
            // The command sends one byte more than the tail, so that the
            // first line, dropped, ends where a whole record starts.
            startsCut = size > transcriptTail + 1;
            initial = startsCut ? transcriptTail + 1 : size;
            continue;
          }
          // The first line of a cut read is the end of a cut record.
          if (line != null && (received > 0 || !startsCut)) {
            transcript.add(line);
          }
          received += length;
        }
        // The last record of the file may not have ended yet: its bytes
        // count, so that the records before it show.
        if (header && received + splitter.pending >= initial) {
          _publish ??= Timer(Duration.zero, publish);
        }
      }
    } catch (e) {
      failure = e;
    } finally {
      firstLine?.cancel();
      if (run == _run) _release();
    }
    if (!current()) return;
    // What came and is not shown yet; or the read ended early: what came.
    final unshown = _publish != null;
    _publish?.cancel();
    if (unshown || (header && received < initial && view.value.items == null)) {
      publish();
    }
    if (!header) {
      final why = '${failure ?? 'no transcript header'}';
      debugPrint('shellherd: no transcript for session $session: $why');
      _why = why.trim().split('\n').first;
      unavailable.value = true;
      return;
    }
    _failures = received > initial ? 0 : _failures + 1;
    _retry = Timer(retryWait(_failures, retryDelay, maxRetryDelay), () {
      _retry = null;
      _start();
    });
  }
}
