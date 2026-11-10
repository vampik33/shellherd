import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:shellherd/ssh/known_hosts.dart';

/// A throwaway OpenSSH server for the current user on 127.0.0.1.
///
/// It runs without root: its own host key, its own authorized key, no PAM.
/// It logs in as the current user with the login shell of that user, so
/// remote commands meet the same shell as a real `ssh localhost`.
class TestSshd {
  TestSshd._(this.port, this._dir, this._process, this._log, this._hostFp);

  final int port;
  final Directory _dir;
  final Process _process;
  final StringBuffer _log;

  /// SHA256 fingerprint of the host key, as `ssh-keygen -l` prints it.
  final String _hostFp;

  /// The host key as the app stores it: type and fingerprint text.
  HostKey get hostKey => HostKey('ssh-ed25519', _hostFp);

  static const _candidates = ['/usr/bin/sshd', '/usr/sbin/sshd'];

  /// The sshd binary, or null. sshd must be started with an absolute path.
  static String? get binary =>
      _candidates.where((p) => File(p).existsSync()).firstOrNull;

  /// Starts on [port], or on a free port. A restart on the same port with
  /// a new host key looks to a client like a changed server key.
  static Future<TestSshd> start({int? port}) async {
    final sshd = binary ?? (throw StateError('no sshd binary'));
    final dir = await Directory.systemTemp.createTemp('shellherd-sshd-');
    TestSshd? server;
    try {
      await Future.wait([
        _keygen('${dir.path}/host_key'),
        _keygen('${dir.path}/client_key'),
      ]);
      await File('${dir.path}/client_key.pub')
          .copy('${dir.path}/authorized_keys');
      final hostFp = await _fingerprint('${dir.path}/host_key.pub');

      port ??= await _freePort();
      await File('${dir.path}/sshd_config').writeAsString('''
Port $port
ListenAddress 127.0.0.1
HostKey ${dir.path}/host_key
AuthorizedKeysFile ${dir.path}/authorized_keys
PidFile ${dir.path}/sshd.pid
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowStreamLocalForwarding yes
''');

      final log = StringBuffer();
      final process = await Process.start(sshd, [
        '-D',
        '-e',
        '-f',
        '${dir.path}/sshd_config',
      ]);
      final listening = Completer<void>();
      process.stdout.transform(utf8.decoder).listen(log.write);
      process.stderr.transform(utf8.decoder).listen((s) {
        log.write(s);
        if (s.contains('Server listening') && !listening.isCompleted) {
          listening.complete();
        }
      });
      server = TestSshd._(port, dir, process, log, hostFp);
      await Future.any([
        listening.future,
        process.exitCode.then(
          (code) => throw StateError('sshd exited with $code:\n$log'),
        ),
      ]).timeout(const Duration(seconds: 10));
      return server;
    } catch (_) {
      // stop() also deletes the directory.
      await (server?.stop() ?? dir.delete(recursive: true));
      rethrow;
    }
  }

  /// Opens an authenticated SSH connection. It accepts only the host key of
  /// this server.
  Future<SSHClient> connect() async {
    final pem = await File('${_dir.path}/client_key').readAsString();
    final client = SSHClient(
      await SSHSocket.connect('127.0.0.1', port),
      username: Platform.environment['USER']!,
      identities: SSHKeyPair.fromPem(pem),
      // dartssh2 passes the fingerprint as the UTF-8 text "SHA256:<base64>".
      onVerifyHostKey: (type, fp) => utf8.decode(fp) == _hostFp,
    );
    try {
      await client.authenticated;
    } catch (e) {
      client.close();
      throw StateError('ssh login failed: $e\nsshd log:\n$log');
    }
    return client;
  }

  String get log => _log.toString();

  /// Lets [publicLine] (an `authorized_keys` line) log in.
  Future<void> authorize(String publicLine) =>
      File('${_dir.path}/authorized_keys')
          .writeAsString('$publicLine\n', mode: FileMode.append);

  /// Sends [signal] to the per-connection sshd processes (all processes
  /// under the listener). SIGSTOP stalls every open connection without
  /// closing it, the way a dead mobile network does; SIGCONT resumes them.
  Future<void> signalConnections(ProcessSignal signal) async {
    final pids = <int>[];
    var parents = [_process.pid];
    while (parents.isNotEmpty) {
      final children = <int>[];
      for (final parent in parents) {
        final r = await Process.run('pgrep', ['-P', '$parent']);
        children.addAll(LineSplitter.split(r.stdout as String).map(int.parse));
      }
      pids.addAll(children);
      parents = children;
    }
    if (pids.isEmpty) throw StateError('sshd has no open connections');
    for (final p in pids) {
      Process.killPid(p, signal);
    }
  }

  Future<void> stop() async {
    _process.kill();
    try {
      await _process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _process.kill(ProcessSignal.sigkill);
      await _process.exitCode;
    }
    if (_dir.existsSync()) await _dir.delete(recursive: true);
  }

  static Future<void> _keygen(String path) async {
    final r = await Process.run('ssh-keygen', [
      '-q',
      '-t',
      'ed25519',
      '-N',
      '',
      '-C',
      'shellherd-test',
      '-f',
      path,
    ]);
    if (r.exitCode != 0) throw StateError('ssh-keygen failed: ${r.stderr}');
  }

  static Future<String> _fingerprint(String pubPath) async {
    final r = await Process.run('ssh-keygen', [
      '-l',
      '-E',
      'sha256',
      '-f',
      pubPath,
    ]);
    if (r.exitCode != 0) throw StateError('ssh-keygen -l failed: ${r.stderr}');
    return (r.stdout as String).split(' ')[1];
  }

  /// A port that was free a moment ago. sshd fails clearly if it is taken.
  static Future<int> _freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = s.port;
    await s.close();
    return port;
  }
}
