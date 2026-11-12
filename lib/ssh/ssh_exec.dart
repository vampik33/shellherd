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
  final session = await openExec(ssh, cmd, timeout);
  try {
    await session.stdin.close();
    final out = await utf8.decoder.bind(session.stdout).join().timeout(timeout);
    await session.done.timeout(timeout, onTimeout: () {});
    return (out, session.exitCode);
  } finally {
    session.channel.destroy();
  }
}

/// Starts [cmd] and returns its session. Throws [TimeoutException] when the
/// channel does not open within [timeout]; one that opens late is
/// destroyed.
Future<SSHSession> openExec(SSHClient ssh, String cmd, Duration timeout) async {
  final open = ssh.execute(cmd);
  try {
    return await open.timeout(timeout);
  } on TimeoutException {
    unawaited(
      open.then<void>((s) => s.channel.destroy(), onError: (Object _) {}),
    );
    rethrow;
  }
}

/// Quotes [s] for `sh`.
String shQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";
