import 'dart:io';

import 'package:shellherd/herdr/api/hc_client.dart';

import 'herdr_test_session.dart';

/// A throwaway herdr-core in its own named session, with its own socket
/// and state directory.
///
/// It must never reach the user's own core. A shell inside the Herdr app
/// has `HC_TERMINAL_SOCKET` pointing at that core, so every `hc` command
/// here runs without the `HC_TERMINAL_*` variables. [stop] stops the core
/// and deletes its state directory.
class HcTestSession {
  HcTestSession._(this.name, this.socketPath);

  final String name;
  final String socketPath;

  /// Opens a client on the socket, as the app does over SSH.
  Future<HcClient> connect() => HcClient.connect(
    SocketHerdrChannel.dialer(socketPath),
    timeout: const Duration(seconds: 10),
  );

  static Future<bool> available() async {
    try {
      return (await Process.run('hc', ['--version'])).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  static String get _runtimeDir =>
      Platform.environment['XDG_RUNTIME_DIR'] ??
      '/run/user/${(Process.runSync('id', ['-u']).stdout as String).trim()}';

  static String get _stateDir =>
      '${Platform.environment['XDG_STATE_HOME'] ?? '${Platform.environment['HOME']}/.local/state'}'
      '/herdr-core';

  Map<String, String> get _environment => {
    for (final MapEntry(:key, :value) in Platform.environment.entries)
      if (!key.startsWith('HC_')) key: value,
    'HC_SESSION': name,
  };

  static Future<HcTestSession> start() async {
    final name = 'shellherd-test-$pid-${DateTime.now().microsecondsSinceEpoch}';
    final session = HcTestSession._(name, '$_runtimeDir/herdr-core/$name.sock');
    final r = await session._hc(['server', 'start', '--json']);
    if (r.exitCode != 0 || !File(session.socketPath).existsSync()) {
      await session.stop();
      throw StateError(
        'hc server start failed (${r.exitCode}): ${r.stdout}${r.stderr}',
      );
    }
    return session;
  }

  Future<ProcessResult> _hc(List<String> args) => Process.run(
    'hc',
    args,
    environment: _environment,
    includeParentEnvironment: false,
  );

  Future<void> stop() async {
    await _hc(['server', 'stop', '--json']);
    final state = Directory('$_stateDir/$name');
    if (name.startsWith('shellherd-test-') && state.existsSync()) {
      await state.delete(recursive: true);
    }
  }
}
