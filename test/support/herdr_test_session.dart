import 'dart:async';
import 'dart:io';

import 'package:shellherd/herdr/api/herdr_client.dart';

/// [HerdrChannel] over a local Unix socket.
class SocketHerdrChannel implements HerdrChannel {
  SocketHerdrChannel(this._socket);
  final Socket _socket;

  static HerdrDialer dialer(String path) => () async => SocketHerdrChannel(
    await Socket.connect(InternetAddress(path, type: InternetAddressType.unix), 0),
  );

  @override
  Stream<List<int>> get input => _socket;

  @override
  void write(List<int> bytes) => _socket.add(bytes);

  @override
  Future<void> close() async => _socket.destroy();
}

/// A throwaway headless herdr server in its own named session.
///
/// Panes run `/bin/sh` so the user's interactive shell config cannot
/// interfere. [stop] stops the server and deletes the session directory.
class HerdrTestSession {
  HerdrTestSession._(this.name, this.socketPath, this._server, this._log);

  final String name;
  final String socketPath;
  final Process _server;
  final StringBuffer _log;

  late final HerdrClient client = HerdrClient(
    SocketHerdrChannel.dialer(socketPath),
    timeout: const Duration(seconds: 10),
  );

  static Future<bool> herdrAvailable() async {
    try {
      return (await Process.run('herdr', ['--version'])).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  static Future<HerdrTestSession> start() async {
    final name = 'shellherd-test-$pid-${DateTime.now().microsecondsSinceEpoch}';
    final home = Platform.environment['HOME']!;
    final socketPath = '$home/.config/herdr/sessions/$name/herdr.sock';
    final log = StringBuffer();
    final server = await Process.start(
      'herdr',
      ['--session', name, 'server'],
      environment: {'SHELL': '/bin/sh'},
    );
    server.stdout.transform(const SystemEncoding().decoder).listen(log.write);
    server.stderr.transform(const SystemEncoding().decoder).listen(log.write);

    final session = HerdrTestSession._(name, socketPath, server, log);
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (true) {
        try {
          await session.client.ping();
          return session;
        } on HerdrException {
          if (DateTime.now().isAfter(deadline)) {
            throw StateError('herdr server did not answer ping:\n$log');
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    } catch (_) {
      // Any failure here must not leave a server and session dir behind.
      await session.stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    await Process.run('herdr', ['--session', name, 'server', 'stop']);
    try {
      await _server.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _server.kill(ProcessSignal.sigkill);
      await _server.exitCode;
    }
    final del = await Process.run('herdr', ['session', 'delete', name]);
    if (del.exitCode != 0) {
      throw StateError(
        'herdr session delete $name failed: ${del.stderr}\nserver log:\n$_log',
      );
    }
  }

  /// Creates a workspace through the raw API and returns its root pane id.
  Future<String> createWorkspace(String label) async {
    final r = await client.request('workspace.create', {
      'cwd': Directory.systemTemp.path,
      'label': label,
      'focus': false,
    });
    final pane = r['root_pane']! as Map<String, Object?>;
    return pane['pane_id']! as String;
  }

  /// Polls `pane.read` until [test] holds for the text or [timeout] passes.
  Future<String> waitForText(
    String paneId,
    bool Function(String text) test, {
    ReadFormat format = ReadFormat.text,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var last = '';
    while (DateTime.now().isBefore(deadline)) {
      last = (await client.paneRead(paneId, format: format, lines: 50)).text;
      if (test(last)) return last;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('pane $paneId never matched; last text:\n$last');
  }
}
