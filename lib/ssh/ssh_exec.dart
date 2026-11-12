import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

/// Runs [cmd] and returns its stdout and exit code. Not [SSHClient.run]:
/// that has no deadline and leaves stdin open. Here stdin gets EOF at once,
/// so a startup file that reads it cannot block.
///
/// The open and the read each throw [TimeoutException] after [timeout]; a
/// channel that opens late is destroyed. The exit code is null when it does
/// not come within [timeout] after the output ends.
Future<(String, int?)> sshExec(
  SSHClient ssh,
  String cmd,
  Duration timeout,
) async {
  final open = ssh.execute(cmd);
  final SSHSession session;
  try {
    session = await open.timeout(timeout);
  } on TimeoutException {
    unawaited(
      open.then<void>((s) => s.channel.destroy(), onError: (Object _) {}),
    );
    rethrow;
  }
  try {
    await session.stdin.close();
    final out = await utf8.decoder.bind(session.stdout).join().timeout(timeout);
    await session.done.timeout(timeout, onTimeout: () {});
    return (out, session.exitCode);
  } finally {
    session.channel.destroy();
  }
}
