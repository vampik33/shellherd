import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../bounded_open.dart';

/// Runs [cmd] and returns its stdout and exit code. Not [SSHClient.run]:
/// that has no deadline and leaves stdin open. Here stdin gets EOF at once,
/// so a startup file that reads it cannot block.
///
/// The open and the read each throw [TimeoutException] after [timeout]; a
/// channel that opens late is destroyed. The exit code is null when it does
/// not come within [timeout] after the output ends.
///
/// With [maxBytes], the read stops there, and the exit code is null. With
/// [allowMalformed], bad UTF-8, such as a character cut by `head -c`,
/// becomes U+FFFD instead of a [FormatException].
Future<(String, int?)> sshExec(
  SSHClient ssh,
  String cmd,
  Duration timeout, {
  int? maxBytes,
  bool allowMalformed = false,
}) async {
  final session = await openExec(ssh, cmd, timeout);
  try {
    await session.stdin.close();
    final bytes = BytesBuilder(copy: false);
    var cut = false;
    await () async {
      await for (final chunk in session.stdout) {
        bytes.add(chunk);
        if (maxBytes != null && bytes.length >= maxBytes) {
          cut = true;
          break;
        }
      }
    }().timeout(timeout);
    final out = utf8.decode(bytes.takeBytes(), allowMalformed: allowMalformed);
    if (cut) return (out, null);
    await session.done.timeout(timeout, onTimeout: () {});
    return (out, session.exitCode);
  } finally {
    session.channel.destroy();
  }
}

/// Starts [cmd] and returns its session. Throws [TimeoutException] when the
/// channel does not open within [timeout]; one that opens late is
/// destroyed.
Future<SSHSession> openExec(SSHClient ssh, String cmd, Duration timeout) =>
    boundedOpen(ssh.execute(cmd), timeout, (s) => s.channel.destroy());

/// Quotes [s] for `sh`.
String shQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// A command on its own exec channel, whose output a reader takes.
abstract interface class ExecChannel {
  /// What the command prints. Ends when it exits; with an error when it
  /// failed.
  Stream<List<int>> get output;

  /// Ends the command.
  void close();
}

/// A command exited with [code] and wrote [stderr].
class ExecFailed implements Exception {
  const ExecFailed(this.what, this.code, this.stderr);

  /// The command, in the message.
  final String what;
  final int code;
  final String stderr;

  @override
  String toString() => '$what: exit $code: $stderr';
}

/// An [ExecChannel] on [session], an exec of the command [what] names.
class SshExecChannel implements ExecChannel {
  SshExecChannel(this._session, this._what) {
    _stderr = utf8.decoder
        .bind(_session.stderr)
        .join()
        .catchError((Object _) => '');
  }

  final SSHSession _session;

  /// The command, in errors.
  final String _what;
  late final Future<String> _stderr;

  /// stdout, then an [ExecFailed] when the command failed.
  @override
  Stream<List<int>> get output async* {
    yield* _session.stdout;
    await _session.done.timeout(const Duration(seconds: 5), onTimeout: () {});
    final code = _session.exitCode;
    if (code != null && code != 0) {
      throw ExecFailed(_what, code, (await _stderr).trim());
    }
  }

  /// Ends stdin first: a command built with [untilStdinEnds] stops its
  /// program when stdin ends, which it also does when the SSH connection
  /// goes.
  @override
  void close() {
    unawaited(_session.stdin.close().catchError((Object _) {}));
    _session.channel.destroy();
  }
}

/// Lines of `sh` that run [command] in the background and stop it when
/// stdin ends, then exit with its status. A program that loses its reader
/// can keep running until it next prints, maybe never; stdin ends when the
/// app closes the channel or the SSH connection goes.
List<String> untilStdinEnds(String command) => [
  'exec 3<&0',
  '$command </dev/null 3<&- &',
  'p=\$!',
  '{ cat <&3 >/dev/null 2>&1; kill \$p 2>/dev/null; } >/dev/null 2>&1 &',
  'w=\$!',
  'exec 3<&-',
  'wait \$p; s=\$?',
  'kill \$w 2>/dev/null',
  'exit \$s',
];
