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
    'd="\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/projects"',
    '[ -d "\$d" ] || { echo "no Claude Code transcripts in \$d" >&2; exit 66; }',
    'find_f() {',
    '  f=',
    '  for g in "\$d"/*/$session.jsonl; do',
    '    [ -r "\$g" ] || continue',
    '    { [ -z "\$f" ] || [ "\$g" -nt "\$f" ]; } && f=\$g',
    '  done',
    '}',
    'find_f',
    'start=0',
    'if [ -n "\$f" ]; then',
    '  size=\$((\$(wc -c < "\$f")))',
    '  ino=\$(ls -i -- "\$f" | { read -r i _; echo "\$i"; })',
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
