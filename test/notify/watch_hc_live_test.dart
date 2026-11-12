/// Runs [WatchHub] over real SSH (a throwaway sshd on 127.0.0.1) against a
/// real herdr-core in a throwaway session, whose agent reports its status
/// with OSC 7501. It never touches the user's own core (see
/// [HcTestSession]). Skipped when `hc` or `sshd` is missing.
@Tags(['hc', 'sshd'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/hc_client.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/hc_snapshot.dart';
import 'package:shellherd/notify/watch_hub.dart';
import 'package:shellherd/ssh/host.dart';
import 'package:shellherd/ssh/json_file.dart';
import 'package:shellherd/ssh/key_store.dart';
import 'package:shellherd/ssh/known_hosts.dart';
import 'package:shellherd/ssh/ssh_connector.dart';

import '../support/hc_test_session.dart';
import '../support/memory_secret_store.dart';
import '../support/poll.dart';
import '../support/recording_notifier.dart';
import '../support/test_sshd.dart';

Future<void> main() async {
  final skip = !await HcTestSession.available()
      ? 'hc is not on PATH'
      : TestSshd.binary == null
      ? 'no sshd'
      : null;

  group('WatchHub on a real Herdr app core over ssh', skip: skip ?? false, () {
    late HcTestSession core;
    late HcClient client;
    late TestSshd sshd;
    late Directory dir;
    late HostStore hosts;
    late WatchHub hub;
    late RecordingNotifier notifier;
    late String keyId;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('shellherd-watch-hc-');
      (core, sshd) = await (HcTestSession.start(), TestSshd.start()).wait;
      client = await core.connect();
      final keys = KeyStore(MemorySecretStore());
      keyId = await keys.generate();
      await sshd.authorize(await keys.publicLine(keyId));
      final knownHosts = KnownHosts(
        JsonFile(File('${dir.path}/known_hosts.json')),
      );
      await knownHosts.trust('127.0.0.1', sshd.port, sshd.hostKey);
      hosts = HostStore(JsonFile(File('${dir.path}/hosts.json')));
      notifier = RecordingNotifier();
      hub = WatchHub.ssh(
        hosts,
        SshConnector(
          knownHosts: knownHosts,
          keys: keys,
          askTrust: (_, _) async => false,
          timeout: const Duration(seconds: 5),
        ),
        notifier,
      );
    });
    tearDown(() async {
      hub.dispose();
      await client.close();
      await sshd.stop();
      await core.stop();
      await dir.delete(recursive: true);
    });

    Future<void> report(String agent, String state) =>
        client.send(agent, HcTestSession.report(state, app: 'claude'));

    Future<void> statusIs(String agent, AgentStatus status) => eventually(
      () async => hcAgentStatus(await client.terminal(agent)) == status,
      'a ${status.name} agent',
    );

    /// Starts a working agent, the one in its tab, and watches the core
    /// over SSH. Returns the agent's address.
    Future<String> watchWorkingAgent() async {
      final agent = await client.run(
        ['sh', '-c', HcTestSession.agentScript],
        labels: {'herdr.seen': '0'},
      );
      await client.writeLayout([agent]);
      await report(agent, 'working');
      await statusIs(agent, AgentStatus.working);
      await hosts.save(
        Host(
          id: 'a',
          label: 'box-a',
          address: '127.0.0.1',
          port: sshd.port,
          user: Platform.environment['USER']!,
          keyId: keyId,
          herdrKind: HerdrKind.herdrApp,
          herdrSession: core.name,
          notify: true,
        ),
      );
      await hub.reload();
      await until(
        () => hub.summary.value == 'box-a: watching',
        'the watcher to go live',
      );
      return agent;
    }

    test('a finish the app marks seen at once notifies as done, and working '
        'again takes it back', () async {
      final agent = await watchWorkingAgent();

      // The Herdr app, its window active with the agent on screen, has
      // seen the turn that is about to end: the core never reports done.
      await client.label(agent, {'herdr.seen': '1'});
      await report(agent, 'idle');
      await until(() => notifier.shown.isNotEmpty, 'a notification');
      final (shownHost, alert) = notifier.shown.single;
      expect(shownHost.id, 'a');
      expect(alert.paneId, agent);
      expect(alert.status, AgentStatus.done);
      expect(alert.agent, 'claude');
      expect(alert.where, 'work › 1');
      expect(hcAgentStatus(await client.terminal(agent)), AgentStatus.idle);

      await report(agent, 'working');
      await until(() => notifier.cancelled.isNotEmpty, 'the cancel');
      expect(notifier.cancelled.single, ('a', agent));
      expect(notifier.shown, hasLength(1));
    });

    test('a finish nobody saw notifies once', () async {
      final agent = await watchWorkingAgent();

      await report(agent, 'idle');
      await statusIs(agent, AgentStatus.done);
      await until(() => notifier.shown.isNotEmpty, 'a notification');
      // The status and the turn come as two events: whether the watcher
      // saw idle between them or not, one notification. Working again
      // comes after both, so its cancel shows they are through.
      await report(agent, 'working');
      await until(() => notifier.cancelled.isNotEmpty, 'the cancel');
      expect(
        [for (final (_, a) in notifier.shown) a.status],
        [AgentStatus.done],
      );
    });
  });
}
