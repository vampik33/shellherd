import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../../ssh/ssh_exec.dart';
import 'transcript_stream.dart';

/// A [TranscriptOpener] that runs [transcriptCommand] on the remote host,
/// each read on its own exec channel.
TranscriptOpener sshTranscriptOpener(
  SSHClient ssh, {
  Duration timeout = const Duration(seconds: 15),
}) =>
    (session, from) async => SshExecChannel(
      await openExec(ssh, transcriptCommand(session, from: from), timeout),
      'transcript read',
    );

/// Claude Code session ids are UUIDs. Only these characters reach the
/// command: a quote or a backslash would also break the quoting for
/// fish, which reads both inside single quotes.
final claudeSessionId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

/// Finds the transcript of Claude Code session [session] on the remote host,
/// `<config>/projects/<project>/<session>.jsonl` with the config directory
/// in CLAUDE_CONFIG_DIR or `~/.claude` (the newest if there are several),
/// and prints a header line ([transcriptHeader]), then the file from where
/// the read starts, and each line added to it, until stdin ends.
///
/// The read starts at the line of [from] when the file has its inode, is
/// not shorter than its offset, and grew by at most [transcriptTail] past
/// it: the reader has the lines before the offset, and checks that the
/// file still has the line before it. Otherwise at the last
/// [transcriptTail] bytes and the one before them, or at the start of a
/// smaller file.
///
/// Claude Code writes the file with the first message, after herdr learns
/// of the session: until the file is there, the header says 0 and the
/// command waits for it, then reads it from the start. Without the
/// projects directory, Claude Code keeps its transcripts elsewhere: it
/// exits 66 then.
///
/// Through `sh`, because the login shell can be fish. Throws
/// [ArgumentError] for an id or a mark it does not take.
String transcriptCommand(String session, {TranscriptMark? from}) {
  if (!claudeSessionId.hasMatch(session)) {
    throw ArgumentError.value(session, 'session', 'not a session id');
  }
  if (from != null &&
      (!transcriptInode.hasMatch(from.inode) ||
          from.line < 0 ||
          from.line > from.offset)) {
    throw ArgumentError.value(from, 'from', 'not a transcript mark');
  }
  const cut = transcriptTail + 1;
  final inner = [
    ..._findTranscript(session),
    'start=0',
    'if [ -n "\$f" ]; then',
    for (final line in _sizeAndInode) '  $line',
    '  if [ "\$size" -gt $cut ]; then start=\$((size - $cut)); fi',
    if (from != null) ...[
      '  if [ "\$ino" = ${from.inode} ] && [ "\$size" -ge ${from.offset} ] &&',
      '    [ \$((size - ${from.offset})) -le $transcriptTail ]; then',
      '    start=${from.line}',
      '  fi',
    ],
    '  echo "$transcriptHeader\$size \$start \${ino:--}"',
    'else',
    '  echo "${transcriptHeader}0 0 -"',
    'fi',
    ...untilStdinEnds(
      '{ while [ -z "\$f" ]; do sleep 1; find_f; done; '
      'exec tail -c +\$((start + 1)) -F -- "\$f"; }',
    ),
  ].join('\n');
  return 'sh -c ${shQuote(inner)}';
}

/// Lines of `sh` that set `d` to Claude Code's projects directory, or
/// exit 66 without one.
const _projects = [
  'd="\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/projects"',
  '[ -d "\$d" ] || { echo "no Claude Code transcripts in \$d" >&2; exit 66; }',
];

/// Lines of `sh` that set `f` to the transcript of Claude Code session
/// [session] (see [transcriptCommand]), empty while there is none, and
/// define `find_f` to look again. Without the projects directory they exit
/// 66.
List<String> _findTranscript(String session) => [
  ..._projects,
  'find_f() {',
  '  f=',
  '  for g in "\$d"/*/$session.jsonl; do',
  '    [ -r "\$g" ] || continue',
  '    { [ -z "\$f" ] || [ "\$g" -nt "\$f" ]; } && f=\$g',
  '  done',
  '}',
  'find_f',
];

/// Lines of `sh` that set `size` and `ino` for the file `f`.
const _sizeAndInode = [
  'size=\$((\$(wc -c < "\$f")))',
  'ino=\$(ls -i -- "\$f" | { read -r i _; echo "\$i"; })',
];

/// A [TranscriptRangeReader] that runs [transcriptRangeCommand] on the
/// remote host. A range can take a while over a slow link: the read may
/// take [readTimeout].
TranscriptRangeReader sshTranscriptRangeReader(
  SSHClient ssh, {
  Duration timeout = const Duration(seconds: 15),
  Duration readTimeout = const Duration(seconds: 60),
}) => (session, range) async {
  final (out, code) = await sshExecBytes(
    ssh,
    transcriptRangeCommand(session, range),
    timeout,
    readTimeout: readTimeout,
    maxBytes: range.to - range.from + _maxNoise,
  );
  if (code == 65) {
    throw const TranscriptRangeFailed('no such transcript', changed: true);
  }
  if (code != 0) {
    throw TranscriptRangeFailed('the read exited ${code ?? 'without a code'}');
  }
  return transcriptRangeBody(out, range);
};

/// How much a remote shell's startup files may print before the header of
/// a range read.
const _maxNoise = 64 * 1024;

/// Prints a header line ([transcriptHeader], with the size of the
/// transcript of Claude Code session [session] that has the inode of
/// [range], the start of [range] and that inode), then the bytes of [range]
/// when the file reaches its end; [transcriptRangeBody] checks. The file is
/// the one a [transcriptCommand] read, even where another of the session
/// is newer now, and the bytes are those of the file checked, opened once.
/// Exits 65 without one, 66 without the projects directory.
///
/// Throws [ArgumentError] for an id or a range it does not take.
String transcriptRangeCommand(String session, TranscriptRange range) {
  if (!claudeSessionId.hasMatch(session)) {
    throw ArgumentError.value(session, 'session', 'not a session id');
  }
  if (!transcriptInode.hasMatch(range.inode) ||
      range.from < 0 ||
      range.to <= range.from) {
    throw ArgumentError.value(range, 'range', 'not a transcript range');
  }
  final inner = [
    ..._projects,
    'f=',
    'for g in "\$d"/*/$session.jsonl; do',
    '  [ -r "\$g" ] || continue',
    '  i=\$(ls -i -- "\$g" | { read -r i _; echo "\$i"; })',
    '  [ "\$i" = ${range.inode} ] && { f=\$g; break; }',
    'done',
    '[ -n "\$f" ] || { echo "no transcript of session $session with inode ${range.inode}" >&2; exit 65; }',
    // Opened once: an inode that matches after the open is that of fd 3,
    // whatever is renamed over the path then. `command` keeps a failed
    // open from ending sh before the exit.
    'command exec 3< "\$f" || exit 65',
    ..._sizeAndInode,
    'echo "$transcriptHeader\$size ${range.from} \${ino:--}"',
    '[ "\$ino" = ${range.inode} ] && [ "\$size" -ge ${range.to} ] || exit 0',
    'tail -c +${range.from + 1} <&3 | head -c ${range.to - range.from}',
  ].join('\n');
  return 'sh -c ${shQuote(inner)}';
}

/// The bytes of [range] in [output], the output of
/// [transcriptRangeCommand]. Throws [TranscriptRangeFailed] when its header
/// is missing, when the file is not the one of the range any more or is
/// shorter, or when the bytes are not all there.
List<int> transcriptRangeBody(List<int> output, TranscriptRange range) {
  var lineStart = 0;
  while (lineStart < output.length) {
    var end = output.indexOf(0x0a, lineStart);
    if (end < 0) end = output.length;
    final at = transcriptStart(
      utf8.decode(output.sublist(lineStart, end), allowMalformed: true),
    );
    lineStart = end + 1;
    if (at == null) continue;
    if (at.inode != range.inode || at.size < range.to) {
      throw const TranscriptRangeFailed(
        'the transcript changed',
        changed: true,
      );
    }
    final body = lineStart >= output.length
        ? const <int>[]
        : output.sublist(lineStart);
    if (body.length != range.to - range.from) {
      throw TranscriptRangeFailed(
        'read ${body.length} bytes of ${range.to - range.from}',
      );
    }
    return body;
  }
  throw const TranscriptRangeFailed('no transcript header');
}
