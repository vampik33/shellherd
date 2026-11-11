/// Runs the Herdr app backend against a real herdr-core in a throwaway
/// session: directly on its socket, and over SSH to a throwaway sshd on
/// 127.0.0.1. It never touches the user's own core (see
/// [HcTestSession]). Skipped when `hc` or `sshd` is missing.
@Tags(['hc', 'sshd'])
library;

import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/hc_client.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/hc_cache.dart';
import 'package:shellherd/herdr/hc_link.dart';
import 'package:shellherd/herdr/hc_snapshot.dart';
import 'package:shellherd/herdr/server_api.dart';

import '../support/hc_test_session.dart';
import '../support/poll.dart';
import '../support/test_sshd.dart';

/// Reads lines and reports each as OSC 7501, as an agent does. It stays in
/// front, so its status holds (a shell prompt clears it).
const _agentScript =
    r'stty -echo; while IFS= read -r l; do printf "\033]7501;%s\007" "$l"; done';

Future<void> main() async {
  final skip = !await HcTestSession.available()
      ? 'hc is not on PATH'
      : TestSshd.binary == null
      ? 'sshd is not installed'
      : null;

  late HcTestSession core;
  late HcClient client;
  HcTestSession? startedCore;

  setUpAll(() async {
    if (skip != null) return;
    core = startedCore = await HcTestSession.start();
  });
  tearDownAll(() async => startedCore?.stop());

  /// Starts [argv] in a terminal of space s1, tab b1 and returns its
  /// address.
  Future<String> run(List<String> argv, {String tab = 'b1'}) async {
    final r = await client.request('terminal.run', {
      'argv': argv,
      'wait': false,
      'size': {'cols': 80, 'rows': 24},
      'labels': {'herdr.space': 's1', 'herdr.tab': tab},
    });
    return r['address']! as String;
  }

  Future<void> writeLayout(
    List<String> terminals, {
    String tabName = '',
  }) async {
    final current = await client.request('doc.get', {'name': 'herdr-app'});
    await client.request('doc.set', {
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

  Future<HcTerminal> terminal(String address) async =>
      (await client.terminals()).singleWhere((t) => t.address == address);

  /// [payload] as an OSC 7501 report, `msg` in base64 as the core wants it.
  /// It goes in as shell text: the script has no status until it reports.
  String report(String state, {String? msg}) => [
    'state=$state',
    'app=demo',
    if (msg != null) 'msg=${base64.encode(utf8.encode(msg))}',
  ].join(':');

  group('herdr-core', skip: skip ?? false, () {
    setUp(() async => client = await core.connect());
    tearDown(() async {
      final live = await client.terminals();
      for (final t in live) {
        await client.request('terminal.kill', {'terminal': t.address});
      }
      await client.close();
    });

    test('says hello in generation 1', () {
      expect(client.hello.generation, HcClient.generation);
      expect(client.hello.version, isNotEmpty);
    });

    test(
      'the cache follows the layout, the terminals and their status',
      () async {
        final shell = await run(['sh']);
        final agent = await run(['sh', '-c', _agentScript]);
        await writeLayout([shell, agent]);
        final snapshots = <HerdrSnapshot>[];
        final cache = HcCache(client, onSnapshot: snapshots.add);
        addTearDown(cache.close);
        await cache.start();
        HerdrSnapshot last() => snapshots.last;
        expect(last().workspaces.single.label, 'work');
        expect(last().panes.map((p) => p.id), [shell, agent]);
        expect(last().agents, isEmpty);

        // A layout change comes as a doc event.
        await writeLayout([shell, agent], tabName: 'fix login');
        await until(
          () => last().tabs.single.label == 'fix login',
          'the rename',
        );

        // A status report comes as an event.
        await HcPaneApi(
          client,
        ).submit(agent, report('working', msg: 'reading x.rs'), toAgent: false);
        await until(
          () => last().agents.singleOrNull?.status == AgentStatus.working,
          'a working agent',
        );
        expect(last().agents.single.title, 'reading x.rs');
        expect(last().agents.single.displayAgent, 'demo');
      },
    );

    test(
      'a finished turn nobody saw is done, until the app has seen it',
      () async {
        final agent = await run(['sh', '-c', _agentScript]);
        await writeLayout([agent]);
        await client.request('terminal.label', {
          'terminal': agent,
          'labels': {'herdr.seen': '0'},
        });
        final api = HcPaneApi(client);
        await api.submit(agent, report('working'), toAgent: false);
        await api.submit(agent, report('idle'), toAgent: false);
        Future<AgentStatus> status() async =>
            hcAgentStatus(await terminal(agent));
        await eventually(
          () async => await status() == AgentStatus.done,
          'a done agent',
        );
        await client.request('terminal.label', {
          'terminal': agent,
          'labels': {'herdr.seen': '1'},
        });
        expect(await status(), AgentStatus.idle);
      },
    );

    test('a blocked agent refuses text', () async {
      final agent = await run(['sh', '-c', _agentScript]);
      final api = HcPaneApi(client);
      await api.submit(agent, report('blocked'), toAgent: false);
      await eventually(
        () async => (await terminal(agent)).status?.state == 'blocked',
        'a blocked agent',
      );
      await expectLater(
        api.submit(agent, 'hello', toAgent: true),
        throwsA(
          isA<HerdrApiException>().having(
            (e) => e.code,
            'code',
            'agent_blocked',
          ),
        ),
      );
    });

    test('text for an agent that quit to its shell is not sent', () async {
      final shell = await run(['sh']);
      final api = HcPaneApi(client);
      await api.submit(shell, "sh -c '$_agentScript'", toAgent: false);
      await api.submit(shell, report('idle'), toAgent: false);
      await eventually(
        () async => (await terminal(shell)).status?.state == 'idle',
        'an idle agent',
      );
      // End of input: the agent exits, and the shell is in front again.
      await api.keys(shell, ['ctrl+d']);
      await eventually(
        () async => (await terminal(shell)).status == null,
        'the status cleared',
      );
      await expectLater(
        api.submit(shell, r'echo LEAK_$((40+2))', toAgent: true),
        throwsA(
          isA<HerdrApiException>().having(
            (e) => e.code,
            'code',
            'agent_not_ready',
          ),
        ),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      final screen = await api.read(shell, source: ReadSource.visible);
      expect(screen, isNot(contains('LEAK_42')));
    });

    test('text and keys reach a shell, and its screen reads back', () async {
      final shell = await run(['sh']);
      final api = HcPaneApi(client);
      Future<String> screen() => api.read(shell, source: ReadSource.visible);
      await api.submit(shell, r'echo HELLO_$((40+2))', toAgent: false);
      await eventually(
        () async => (await screen()).contains('HELLO_42'),
        'HELLO_42',
      );
      // Key names are lower case: 'K' presses k.
      for (final key in ['e', 'c', 'h', 'o', 'space', 'k', 'y', 'enter']) {
        await api.keys(shell, [key]);
      }
      var last = '';
      await eventually(
        () async => (last = await screen()).contains('\nky'),
        'ky',
      ).catchError((Object e) => fail('$e on the screen:\n$last'));
      // The key bar of the pane screen sends these names.
      await api.keys(shell, [
        'esc',
        'ctrl+c',
        'tab',
        'shift+tab',
        'up',
        'down',
        'left',
        'right',
        'enter',
        '1',
      ]);
      final history = await api.read(
        shell,
        source: ReadSource.recentUnwrapped,
        lines: 400,
      );
      expect(history, contains('HELLO_42'));
    });

    test('a terminal that is not there is pane_not_found', () async {
      await expectLater(
        HcPaneApi(client).read('t999', source: ReadSource.visible),
        throwsA(
          isA<HerdrApiException>().having(
            (e) => e.code,
            'code',
            'pane_not_found',
          ),
        ),
      );
    });
  });

  group('herdr-core over ssh', skip: skip ?? false, () {
    late TestSshd sshd;
    late SSHClient ssh;
    TestSshd? startedSshd;
    SSHClient? openSsh;

    setUpAll(() async {
      sshd = startedSshd = await TestSshd.start();
      ssh = openSsh = await sshd.connect();
    });
    tearDownAll(() async {
      openSsh?.close();
      await startedSshd?.stop();
    });

    test('finds the session socket through the remote shell', () async {
      final client = await connectHc(ssh, session: core.name);
      addTearDown(client.close);
      expect(client.hello.generation, 1);
      expect(await client.terminals(), isA<List<HcTerminal>>());
    });

    test('no core names the socket it looked for', () async {
      await expectLater(
        connectHc(ssh, session: 'shellherd-test-no-such-core'),
        throwsA(
          isA<HerdrNoSocketException>()
              .having((e) => e.cause, 'cause', isA<SSHChannelOpenError>())
              .having(
                (e) => e.socketPath,
                'socketPath',
                endsWith('/herdr-core/shellherd-test-no-such-core.sock'),
              ),
        ),
      );
    });
  });
}
