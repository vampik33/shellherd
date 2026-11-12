import 'dart:convert';
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

  /// Reads lines and reports each as OSC 7501, as an agent does. It stays
  /// in front, so its status holds (a shell prompt clears it).
  static const agentScript =
      r'stty -echo; while IFS= read -r l; do printf "\033]7501;%s\007" "$l"; done';

  /// [state] as an OSC 7501 report for [agentScript], `msg` in base64 as
  /// the core wants it. It goes in as shell text: the script has no status
  /// until it reports.
  static String report(String state, {String? msg, String app = 'demo'}) => [
    'state=$state',
    'app=$app',
    if (msg != null) 'msg=${base64.encode(utf8.encode(msg))}',
  ].join(':');

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

/// Terminals and a layout in a test core, as the Herdr app keeps them: one
/// space "work" (s1) with one tab (b1).
extension HcTestLayout on HcClient {
  /// Starts [argv] in a terminal of space s1, tab [tab], with [labels]
  /// besides those, and returns its address.
  Future<String> run(
    List<String> argv, {
    String tab = 'b1',
    Map<String, String> labels = const {},
  }) async {
    final r = await request('terminal.run', {
      'argv': argv,
      'wait': false,
      'size': {'cols': 80, 'rows': 24},
      'labels': {'herdr.space': 's1', 'herdr.tab': tab, ...labels},
    });
    return r['address']! as String;
  }

  /// Lays [terminals] out side by side in tab b1.
  Future<void> writeLayout(
    List<String> terminals, {
    String tabName = '',
  }) async {
    final current = await request('doc.get', {'name': 'herdr-app'});
    await request('doc.set', {
      'name': 'herdr-app',
      'version': current['version'],
      'value': {
        'spaces': [
          {
            'id': 's1',
            'name': 'work',
            'folder': '/tmp',
            'tabs': [
              {
                'id': 'b1',
                'name': tabName,
                'root': {
                  'id': 'b1',
                  'type': 'row',
                  'children': [
                    for (final t in terminals)
                      {
                        'id': 'p$t',
                        'type': 'block',
                        'content': {'terminal': t},
                      },
                  ],
                },
              },
            ],
          },
        ],
      },
    });
  }
}
