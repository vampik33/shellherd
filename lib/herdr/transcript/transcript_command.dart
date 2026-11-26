import 'package:dartssh2/dartssh2.dart';

import '../../ssh/ssh_exec.dart';
import 'transcript_stream.dart';

/// A [TranscriptOpener] that runs [transcriptCommand] on the remote host,
/// each read on its own exec channel.
TranscriptOpener sshTranscriptOpener(
  SSHClient ssh, {
  Duration timeout = const Duration(seconds: 15),
}) =>
    (session) async => SshExecChannel(
      await openExec(ssh, transcriptCommand(session), timeout),
      'transcript read',
    );

/// Claude Code session ids are UUIDs. Only these characters reach the
/// command: a quote or a backslash would also break the quoting for
/// fish, which reads both inside single quotes.
final _sessionId = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

/// Finds the transcript of Claude Code session [session] on the remote host,
/// `<config>/projects/<project>/<session>.jsonl` with the config directory
/// in CLAUDE_CONFIG_DIR or `~/.claude` (the newest if there are several),
/// and prints a header line with its size ([transcriptHeader]), then its
/// last [transcriptTail] bytes and the one before them, and each line added
/// to it, until stdin ends.
///
/// Claude Code writes the file with the first message, after herdr learns
/// of the session: until the file is there, the header says 0 and the
/// command waits for it. Without the projects directory, Claude Code keeps
/// its transcripts elsewhere: it exits 66 then.
///
/// Through `sh`, because the login shell can be fish. Throws
/// [ArgumentError] for an id it does not take.
String transcriptCommand(String session) {
  if (!_sessionId.hasMatch(session)) {
    throw ArgumentError.value(session, 'session', 'not a session id');
  }
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
    'if [ -n "\$f" ]; then',
    '  echo "$transcriptHeader\$(wc -c < "\$f")"',
    '  from=${transcriptTail + 1}',
    'else',
    '  echo "${transcriptHeader}0"',
    '  from=+1',
    'fi',
    ...untilStdinEnds(
      '{ while [ -z "\$f" ]; do sleep 1; find_f; done; '
      'exec tail -c "\$from" -F -- "\$f"; }',
    ),
  ].join('\n');
  return 'sh -c ${shQuote(inner)}';
}
