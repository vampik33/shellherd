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

/// Where a read stopped: the file, by its inode, and the last whole line
/// read, from [line], where it starts, to [offset], where it ends: the
/// first byte not read, which starts a line. Both are 0 before the first
/// line of a file.
typedef TranscriptMark = ({String inode, int line, int offset});

/// Starts a read of the transcript of Claude Code session [session] on the
/// remote host: at the line of [from] when it is still the file there and
/// [from] is not too far behind its end, else at its end. A read that goes
/// on sends the last line read again, so that the reader can check that
/// the file still has it there.
typedef TranscriptOpener = Future<TranscriptChannel> Function(
  String session,
  TranscriptMark? from,
);

/// How much of the end of a transcript a read starts with, past the line
/// the cut falls in, and how far behind the end a read can go on from where
/// the last stopped. Transcripts grow to hundreds of megabytes.
const transcriptTail = 2 * 1024 * 1024;

/// The first line of a read: the marker, the size of the file, the offset
/// the read starts at, and the file's inode, `-` while there is no file.
/// Lines before it come from the remote shell's startup files.
const transcriptHeader = 'shellherd-transcript ';

/// What a header line says; null for any other line. [inode] is null while
/// there is no file.
typedef TranscriptStart = ({int size, int start, String? inode});

/// The inodes that a mark takes: the command gets them back.
final transcriptInode = RegExp(r'^[0-9]{1,20}$');

final _spaces = RegExp(r'\s+');

/// What the header [line] says; null for any other line. A startup file
/// can print text without a newline: it then stands before the marker.
TranscriptStart? transcriptStart(String line) {
  final at = line.indexOf(transcriptHeader);
  if (at < 0) return null;
  final words = line
      .substring(at + transcriptHeader.length)
      .trim()
      .split(_spaces);
  if (words.length != 3) return null;
  final size = int.tryParse(words[0]);
  final start = int.tryParse(words[1]);
  if (size == null || start == null || start < 0) return null;
  final inode = words[2];
  return (
    size: size,
    start: start,
    inode: transcriptInode.hasMatch(inode) ? inode : null,
  );
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

/// The bytes of a transcript from [from] to [to], in the file with
/// [inode].
typedef TranscriptRange = ({String inode, int from, int to});

/// Reads the bytes [TranscriptRange.from] to [TranscriptRange.to] of the
/// transcript of Claude Code session [session] on the remote host. Throws
/// when the file is not the one with the range's inode any more, or is
/// shorter than its end.
typedef TranscriptRangeReader = Future<List<int>> Function(
  String session,
  TranscriptRange range,
);

/// A range read did not bring the bytes asked for.
class TranscriptRangeFailed implements Exception {
  const TranscriptRangeFailed(this.why, {this.changed = false});
  final String why;

  /// The file is not the one with the range's inode any more, or is
  /// shorter than its end: a new read must start over.
  final bool changed;

  @override
  String toString() => 'TranscriptRangeFailed: $why';
}

/// How much more than the first read's [transcriptTail] the chat loads
/// when the user scrolls up: the phone keeps all of it. No load starts
/// once this much came; the last one can bring more, up to [transcriptTail]
/// or the line it ends in.
const maxEarlierBytes = 18 * 1024 * 1024;

/// What a read of the bytes before the part of a transcript held gave.
typedef EarlierLines = ({
  /// The whole lines, oldest first, without their newlines.
  List<List<int>> lines,

  /// Where the part held starts now.
  int start,

  /// [start] lies inside a line that is too long to keep; the bytes
  /// before it up to that line's start are dropped.
  bool inLine,
});

/// The lines of [bytes], the bytes of a transcript from [readFrom] to
/// where the part held starts. That is the start of a line, or with
/// [inLine] a place in a line longer than [maxLine], which is dropped.
///
/// Past the start of the file, the bytes start one byte before the first
/// line they may hold: the line they start in is cut, and dropped. Lines
/// longer than [maxLine] are dropped, as [ByteLines] does.
///
/// Null when [bytes] lie inside one line that may be short enough to keep:
/// a read of more must find its start.
EarlierLines? earlierLines(
  List<int> bytes, {
  required int readFrom,
  required bool inLine,
  int maxLine = maxTranscriptLine,
}) {
  // Without [inLine], the bytes end with the newline of the line before
  // the part held.
  if (bytes.isEmpty || (!inLine && bytes.last != 0x0a)) {
    throw ArgumentError.value(bytes, 'bytes', 'do not end a line');
  }
  final newlines = [
    for (var i = 0; i < bytes.length; i++)
      if (bytes[i] == 0x0a) i,
  ];
  if (newlines.isEmpty) {
    // All of it lies inside the line being dropped.
    if (readFrom == 0) return (lines: const [], start: 0, inLine: false);
    if (!inLine && bytes.length - 1 <= maxLine) return null;
    return (lines: const [], start: readFrom + 1, inLine: true);
  }
  final lastEnd = newlines.last;
  final ends = inLine ? newlines : newlines.sublist(0, newlines.length - 1);
  if (readFrom > 0 && ends.isEmpty) {
    // One line, up to the part held: its start is further back.
    if (bytes.length - 1 <= maxLine) return null;
    return (lines: const [], start: readFrom + 1, inLine: true);
  }
  final lines = <List<int>>[];
  var lineStart = 0;
  for (final end in [...ends, if (!inLine) lastEnd]) {
    if (lineStart > 0 || readFrom == 0) {
      if (end - lineStart <= maxLine) lines.add(bytes.sublist(lineStart, end));
    }
    lineStart = end + 1;
  }
  // Past the start of the file, the first line was cut: the part held
  // starts after it.
  return (
    lines: lines,
    start: readFrom == 0 ? 0 : readFrom + newlines.first + 1,
    inLine: false,
  );
}

/// Reads the lines before [start] with [read], [chunk] bytes at first and
/// twice as many while they lie inside one line that may be short enough
/// to keep. [read] gets the range of bytes to read, from and to; each read
/// after the first gets only the bytes before the last.
Future<EarlierLines> readEarlier(
  Future<List<int>> Function(int from, int to) read, {
  required int start,
  required bool inLine,
  int chunk = transcriptTail,
  int maxLine = maxTranscriptLine,
}) async {
  if (start <= 0) throw ArgumentError.value(start, 'start', 'nothing before');
  var size = chunk;
  var readFrom = start;
  var bytes = const <int>[];
  while (true) {
    final from = max(0, start - size);
    // One byte before, to know whether a line starts at [from].
    final before = from == 0 ? 0 : from - 1;
    final more = await read(before, readFrom);
    if (more.length != readFrom - before) {
      throw StateError('read ${more.length} bytes of ${readFrom - before}');
    }
    bytes = [...more, ...bytes];
    readFrom = before;
    final found = earlierLines(
      bytes,
      readFrom: readFrom,
      inLine: inLine,
      maxLine: maxLine,
    );
    if (found != null) return found;
    size = min(size * 2, maxLine + 1);
  }
}

/// How far loading the earlier part of a transcript got.
enum EarlierLoad {
  /// Nothing loads: more can be asked for.
  idle,
  loading,

  /// The last load failed: the user can try again.
  failed,

  /// [maxEarlierBytes] are loaded: no more is.
  capped,

  /// Nothing can load them now, for example before the read found where
  /// its first line starts.
  none,
}

/// What the app knows of a transcript.
class TranscriptView {
  const TranscriptView({
    this.items,
    this.startsCut = false,
    this.firstKey = 0,
    this.earlier = EarlierLoad.idle,
  });

  /// Oldest first; null until a read started.
  final List<ChatItem>? items;

  /// The read began after the start of the file: older messages are not
  /// shown.
  final bool startsCut;

  /// A number for the first of [items], one less for each item loaded in
  /// front of it, so that an item keeps its number while earlier ones
  /// load.
  final int firstKey;

  /// How loading the messages before [items] goes.
  final EarlierLoad earlier;
}

/// The conversation of the Claude Code session in one pane, read from its
/// transcript: the last [transcriptTail] bytes first, then each record as
/// Claude Code adds it. A new read of the same session, after a new link or
/// while the chat was hidden, goes on where the last one stopped. When the
/// line it starts with is not the last line read, the file changed under
/// it: it ends, and the next read starts over.
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
    this._ranges,
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

  /// The range reads of the current link, for [loadEarlier]; null without
  /// a link, or where it has none.
  final TranscriptRangeReader? Function()? _ranges;

  /// When the opener or the session can have changed.
  final Listenable changes;

  /// The longest wait for a read to start and send its header.
  final Duration openTimeout;

  final Duration retryDelay;
  final Duration maxRetryDelay;

  final view = ValueNotifier(const TranscriptView());

  /// True while a read runs and [view] shows all that the file had when it
  /// started, and each line added since: the chat is current.
  final live = ValueNotifier(false);

  /// True after a read of the current link and session failed before its
  /// header.
  final unavailable = ValueNotifier(false);

  /// Why the read failed, while [unavailable]: the first line of the
  /// error, for the user.
  String? get whyUnavailable => _why;
  String? _why;

  TranscriptOpener? _lastOpener;
  String? _lastSession;

  /// What the reads of the session made so far.
  _Kept? _kept;

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
    live.dispose();
  }

  /// Loads the lines before those [view] shows, [transcriptTail] bytes at a
  /// time, and puts their items in front, while the read [startsCut] and
  /// less than [maxEarlierBytes] more came so far. [TranscriptView.earlier]
  /// says how it goes. Does nothing while a load runs, or before a read
  /// showed what it started with.
  ///
  /// A load that ends after the session changed, or after a read started
  /// over, is dropped.
  Future<void> loadEarlier() async {
    final kept = _kept;
    final ranges = _ranges?.call();
    final session = _session();
    if (_closed || kept == null || !kept.shown || ranges == null) return;
    final inode = kept.inode;
    final start = kept.start;
    if (session == null || inode == null || start == null || start == 0) {
      return;
    }
    if (kept.earlier == EarlierLoad.loading) return;
    if (kept.earlierBytes >= maxEarlierBytes) {
      kept.earlier = EarlierLoad.capped;
      _show(kept);
      return;
    }
    kept.earlier = EarlierLoad.loading;
    _show(kept);
    bool current() => !_closed && identical(_kept, kept);
    try {
      final found = await readEarlier(
        (from, to) => ranges(session, (inode: inode, from: from, to: to)),
        start: start,
        inLine: kept.inLine,
      );
      if (!current()) return;
      kept.firstKey -= kept.transcript.prepend(
        found.lines.map((l) => utf8.decode(l, allowMalformed: true)),
      );
      kept.earlierBytes += start - found.start;
      kept.start = found.start;
      kept.inLine = found.inLine;
      kept.cut = found.start > 0;
      kept.earlier = kept.cut && kept.earlierBytes >= maxEarlierBytes
          ? EarlierLoad.capped
          : EarlierLoad.idle;
    } catch (e) {
      if (!current()) return;
      debugPrint('shellherd: cannot load earlier messages of $session: $e');
      if (e is TranscriptRangeFailed && e.changed) {
        // The read holds a file that is not there any more: a new one
        // starts from its end.
        _kept = null;
        _stop();
        _start();
        return;
      }
      kept.earlier = EarlierLoad.failed;
    }
    if (!kept.cut || kept.earlier == EarlierLoad.capped) {
      // Nothing more goes in front.
      kept.transcript.keepRecords = false;
    }
    _show(kept);
  }

  /// Shows what [kept] holds.
  void _show(_Kept kept) {
    kept.shown = true;
    view.value = TranscriptView(
      items: kept.transcript.items,
      startsCut: kept.cut,
      firstKey: kept.firstKey,
      earlier:
          kept.start == null || kept.inode == null || _ranges?.call() == null
          ? EarlierLoad.none
          : kept.earlier,
    );
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
      _kept = null;
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
    live.value = false;
  }

  void _start() {
    if (!_running || _closed || !canRead) return;
    if (_reading || _retry != null) return;
    _reading = true;
    unawaited(_read(_opener()!, _session()!, ++_run));
  }

  Future<void> _read(TranscriptOpener opener, String session, int run) async {
    bool current() => run == _run && !_closed;
    var kept = _kept;
    final from = kept?.mark;
    var transcript = ClaudeTranscript();
    var header = false;
    // The first line of a read that starts past the start of the file and
    // not where the last one stopped is the end of a cut record.
    var dropFirst = false;
    // The first line of a read that goes on must be the last line read;
    // when it is not, the file changed under the mark.
    var check = false;
    var changed = false;
    var start = 0;
    String? inode;
    // The bytes of the file that the read starts with, and how many of
    // them came: the chat shows once all did, so that a new read does not
    // show half of what the last one showed.
    var initial = 0;
    var received = 0;
    Object? failure;
    Timer? firstLine;
    void publish() {
      _publish = null;
      _show(kept!);
      // After the read ended, what it brought shows, but nothing follows.
      live.value = current() && _channel != null;
    }

    try {
      final channel = await openWithin(
        opener(session, from),
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
      read:
      await for (final chunk in channel.output) {
        if (!current()) return;
        for (final (:bytes, size: length) in splitter.add(chunk)) {
          final line = bytes == null
              ? null
              : utf8.decode(bytes, allowMalformed: true);
          if (!header) {
            if (line == null) continue;
            final at = transcriptStart(line);
            if (at == null) continue;
            header = true;
            start = at.start;
            inode = at.inode;
            initial = at.size - start;
            if (from != null && inode == from.inode && start == from.line) {
              transcript = kept!.transcript;
              check = from.line < from.offset;
            } else {
              // The command starts a cut one byte early, so that the
              // first line, dropped, ends where a whole record starts.
              dropFirst = start > 0;
              kept = _kept = _Kept(transcript, cut: dropFirst, inode: inode);
              // A cut read holds from the end of its first line.
              if (!dropFirst) kept.start = start;
              // Only a cut read can get earlier lines in front.
              transcript.keepRecords = dropFirst;
              if (!dropFirst && inode != null) {
                kept.mark = (inode: inode, line: start, offset: start);
              }
            }
            continue;
          }
          if (check) {
            check = false;
            if (bytes == null || !listEquals(bytes, kept!.line)) {
              changed = true;
              break read;
            }
            // Already in the transcript.
          } else if (line != null && (received > 0 || !dropFirst)) {
            transcript.add(line);
          }
          final lineStart = start + received;
          received += length;
          if (dropFirst && lineStart == start) kept!.start = start + received;
          // Only whole lines count: the next read starts a line. A dropped
          // line cannot be checked: the next one sets the mark again.
          if (inode != null) {
            kept!
              ..mark = bytes == null
                  ? null
                  : (inode: inode, line: lineStart, offset: start + received)
              ..line = bytes ?? const [];
          }
        }
        // The last record of the file may not have ended yet: its bytes
        // count, so that the records before it show.
        if (header && !check && received + splitter.pending >= initial) {
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
    _publish = null;
    if (changed) {
      // What the reads made is not the file any more: the next read
      // starts over.
      _kept = null;
    } else if (unshown ||
        (header && received < initial && view.value.items == null)) {
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

/// What the reads of a session made so far, for the next read to go on
/// with.
class _Kept {
  _Kept(this.transcript, {required this.cut, required this.inode});

  final ClaudeTranscript transcript;

  /// The transcript starts after the start of the file.
  bool cut;

  /// The file read; null while there was none.
  final String? inode;

  /// Where the first line of [transcript] starts in the file; null until
  /// the read found it.
  int? start;

  /// [start] lies inside a line too long to keep: see [EarlierLines].
  bool inLine = false;

  /// The bytes [loadEarlier] put in front so far.
  int earlierBytes = 0;

  /// See [TranscriptView.firstKey].
  int firstKey = 0;

  EarlierLoad earlier = EarlierLoad.idle;

  /// The view showed it: what the read started with all came.
  bool shown = false;

  /// Where the last read stopped; null while a read cannot go on from it.
  /// While it is set, [transcript] holds exactly the lines before its
  /// offset, and [line] the bytes of its line, without the newline.
  TranscriptMark? mark;
  List<int> line = const [];
}
