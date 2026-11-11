import 'dart:async';
import 'dart:io';

/// Which login methods a [DockerSshd] offers.
enum PamMode {
  password(offersPassword: true, offersKbdint: false),
  kbdint(offersPassword: false, offersKbdint: true),
  both(offersPassword: true, offersKbdint: true);

  const PamMode({required this.offersPassword, required this.offersKbdint});
  final bool offersPassword;
  final bool offersKbdint;
}

/// Real OpenSSH with PAM in a throwaway Docker container on 127.0.0.1, with
/// the user `dev`. The image comes from test/support/docker/openssh_pam.
///
/// The OpenSSH of [TestSshd] runs without root and so cannot check a
/// password; in the container sshd runs as root and checks it through PAM,
/// as on a real PC.
class DockerSshd {
  DockerSshd._(this.port, this._id);

  static const user = 'dev';
  static const _image = 'shellherd-test-openssh-pam';
  static const _context = 'test/support/docker/openssh_pam';

  /// Marks the containers of these tests.
  static const _label = 'shellherd-test=1';

  final int port;
  final String _id;

  /// Why the tests cannot run here, or null.
  static Future<String?> unavailable() async {
    try {
      final r = await Process.run('docker', ['info', '--format', '{{.ID}}']);
      return r.exitCode == 0 ? null : 'docker does not answer: ${r.stderr}';
    } on ProcessException {
      return 'docker is not installed';
    }
  }

  /// Builds the image. Docker caches it, so only the first build installs
  /// openssh-server, which needs the network.
  static Future<void> build() async {
    final r = await Process.run('docker', [
      'build',
      '-q',
      '-t',
      _image,
      _context,
    ]);
    if (r.exitCode != 0) {
      throw StateError('docker build failed:\n${r.stderr}');
    }
  }

  /// Starts sshd with [mode] and [password] for `dev`. The password goes in
  /// through the environment, not the command line.
  static Future<DockerSshd> start(PamMode mode, String password) async {
    String yesNo(bool on) => on ? 'yes' : 'no';
    final run = await Process.run(
      'docker',
      [
        'run',
        '-d',
        '--rm',
        '--label',
        _label,
        '-p',
        '127.0.0.1::22',
        '--env',
        'SHELLHERD_TEST_PASSWORD',
        _image,
        'sh',
        '-c',
        'printf "$user:%s\\n" "\$SHELLHERD_TEST_PASSWORD" | chpasswd '
            '&& exec /usr/sbin/sshd -D -e -o UsePAM=yes '
            '-o PasswordAuthentication=${yesNo(mode.offersPassword)} '
            '-o KbdInteractiveAuthentication=${yesNo(mode.offersKbdint)}',
      ],
      environment: {'SHELLHERD_TEST_PASSWORD': password},
    );
    if (run.exitCode != 0) {
      throw StateError('docker run failed:\n${run.stderr}');
    }
    final id = (run.stdout as String).trim();
    try {
      final port = await Process.run('docker', ['port', id, '22/tcp']);
      final server = DockerSshd._(
        int.parse(
          (port.stdout as String).trim().split('\n').first.split(':').last,
        ),
        id,
      );
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!(await server.log()).contains('Server listening')) {
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('sshd did not start:\n${await server.log()}');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      return server;
    } catch (_) {
      await Process.run('docker', ['container', 'remove', '-f', id]);
      rethrow;
    }
  }

  /// What sshd has logged so far.
  Future<String> log() async {
    final r = await Process.run('docker', ['logs', _id]);
    return '${r.stdout}${r.stderr}';
  }

  /// The lines of [log] that contain [text].
  Future<List<String>> logLines(String text) async =>
      (await log()).split('\n').where((l) => l.contains(text)).toList();

  Future<void> stop() async {
    await Process.run('docker', ['container', 'remove', '-f', _id]);
  }
}
