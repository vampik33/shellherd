/// Runs [sshExec] over a real SSH connection to a throwaway sshd on
/// 127.0.0.1. Skipped when `sshd` is missing.
@Tags(['sshd'])
@Timeout(Duration(seconds: 60))
library;

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/ssh/ssh_exec.dart';

import '../support/test_sshd.dart';

void main() {
  final skip = TestSshd.binary == null ? 'sshd is not installed' : null;
  const timeout = Duration(seconds: 10);

  late SSHClient ssh;
  TestSshd? startedSshd;
  SSHClient? openSsh;

  setUpAll(() async {
    if (skip != null) return;
    final sshd = startedSshd = await TestSshd.start();
    ssh = openSsh = await sshd.connect();
  });
  tearDownAll(() async {
    openSsh?.close();
    await startedSshd?.stop();
  });

  group('sshExec', skip: skip ?? false, () {
    test('gives the output and the exit code', () async {
      expect(await sshExec(ssh, 'echo hi; exit 3', timeout), ('hi\n', 3));
    });

    test('with maxBytes, stops reading there, without an exit code', () async {
      final watch = Stopwatch()..start();
      final (out, code) = await sshExec(
        ssh,
        'yes | head -c 50000000',
        timeout,
        maxBytes: 4096,
      );
      expect(out.length, greaterThanOrEqualTo(4096));
      expect(out.length, lessThan(50000000));
      expect(code, isNull);
      expect(watch.elapsed, lessThan(timeout));
    });

    test('bad UTF-8 fails, unless allowMalformed', () async {
      const cmd = r"printf '\377ok'";
      await expectLater(sshExec(ssh, cmd, timeout), throwsFormatException);
      expect(await sshExec(ssh, cmd, timeout, allowMalformed: true), (
        '\uFFFDok',
        0,
      ));
    });
  });
}
