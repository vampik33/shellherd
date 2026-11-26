import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'poll.dart';

/// What a [PasswordSshd] offers; see test/support/password_sshd.py.
enum PasswordMode { password, kbdint, both, otp, two, none, check, stuck }

/// A throwaway SSH server on 127.0.0.1 that checks only a password, on
/// paramiko: the OpenSSH of [TestSshd] runs without root and so cannot.
class PasswordSshd {
  PasswordSshd._(this.port, this._process, this.answers);

  final int port;
  final Process _process;

  /// One line for each answer the server got, such as `password bad` or
  /// `kbdint 1 ok`. No password is in it.
  final List<String> answers;

  static const _script = 'test/support/password_sshd.py';

  static Future<bool> available() async {
    try {
      return (await Process.run('python3', [
            '-c',
            'import paramiko',
          ])).exitCode ==
          0;
    } on ProcessException {
      return false;
    }
  }

  static Future<PasswordSshd> start(PasswordMode mode, String password) async {
    final process = await Process.start(
      'python3',
      ['-I', _script, mode.name],
      environment: {'SHELLHERD_TEST_PASSWORD': password},
    );
    final answers = <String>[];
    final port = Completer<int>();
    final errors = StringBuffer();
    process.stderr.transform(utf8.decoder).listen(errors.write);
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.startsWith('PORT ')) {
            port.complete(int.parse(line.substring(5)));
          } else if (line.startsWith('AUTH ')) {
            answers.add(line.substring(5));
          }
        });
    try {
      return PasswordSshd._(
        await Future.any([
          port.future,
          process.exitCode.then<int>(
            (code) => throw StateError('password sshd exited $code:\n$errors'),
          ),
        ]).timeout(const Duration(seconds: 15)),
        process,
        answers,
      );
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
      rethrow;
    }
  }

  /// [answers] once [count] have come. The server prints each answer
  /// before it sends the result, but on its stdout, which the test reads
  /// apart from the SSH connection: a login can return before its answer
  /// is read, as under the load of the full suite.
  Future<List<String>> answered(int count) async {
    await until(
      () => answers.length >= count,
      '$count answers from the server',
    );
    return answers;
  }

  Future<void> stop() async {
    _process.kill();
    await _process.exitCode;
  }
}
