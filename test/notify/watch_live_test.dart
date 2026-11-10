/// Runs [WatchHub] over real SSH (a throwaway sshd on 127.0.0.1) against a
/// real herdr server, whose agent states the test sets with
/// `pane.report_agent`. Skipped when `herdr` or `sshd` is missing.
@Tags(['herdr'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/notify/watch_hub.dart';
import 'package:shellherd/ssh/host.dart';
import 'package:shellherd/ssh/json_file.dart';
import 'package:shellherd/ssh/key_store.dart';
import 'package:shellherd/ssh/known_hosts.dart';
import 'package:shellherd/ssh/ssh_connector.dart';

import '../support/herdr_test_session.dart';
import '../support/memory_secret_store.dart';
import '../support/poll.dart';
import '../support/recording_notifier.dart';
import '../support/test_sshd.dart';

Future<void> main() async {
  final skip = !await HerdrTestSession.herdrAvailable()
      ? 'herdr is not on PATH'
      : TestSshd.binary == null
      ? 'no sshd'
      : null;

  group('WatchHub on real herdr over ssh', skip: skip ?? false, () {
    late HerdrTestSession herdr;
    late TestSshd sshd;
    late Directory dir;
    late HostStore hosts;
    late WatchHub hub;
    late RecordingNotifier notifier;
    late String keyId;
    late KnownHosts knownHosts;
    var asked = 0;

    Host host(String id, String address) => Host(
      id: id,
      label: 'box-$id',
      address: address,
      port: sshd.port,
      user: Platform.environment['USER']!,
      keyId: keyId,
      herdrSession: herdr.name,
      notify: true,
    );

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('shellherd-watch-');
      herdr = await HerdrTestSession.start();
      sshd = await TestSshd.start();
      final keys = KeyStore(MemorySecretStore());
      keyId = await keys.generate();
      await sshd.authorize(await keys.publicLine(keyId));
      knownHosts = KnownHosts(
        JsonFile(File('${dir.path}/known_hosts.json')),
      );
      await knownHosts.trust('127.0.0.1', sshd.port, sshd.hostKey);
      hosts = HostStore(JsonFile(File('${dir.path}/hosts.json')));
      notifier = RecordingNotifier();
      asked = 0;
      hub = WatchHub.ssh(
        hosts,
        SshConnector(
          knownHosts: knownHosts,
          keys: keys,
          askTrust: (_, _) async {
            asked++;
            return false;
          },
          timeout: const Duration(seconds: 5),
        ),
        notifier,
      );
    });
    tearDown(() async {
      hub.dispose();
      await sshd.stop();
      await herdr.stop();
      await dir.delete(recursive: true);
    });

    Future<void> report(String pane, String state) =>
        herdr.client.request('pane.report_agent', {
          'pane_id': pane,
          'source': 'test',
          'agent': 'claude',
          'state': state,
        });

    test('an agent that becomes blocked notifies, and working again takes '
        'it back', () async {
      final pane = await herdr.createWorkspace('api');
      await report(pane, 'working');
      await hosts.save(host('a', '127.0.0.1'));
      await hub.reload();
      await until(
        () => hub.summary.value == 'box-a: watching',
        'the watcher to go live',
      );

      await report(pane, 'blocked');
      await until(() => notifier.shown.isNotEmpty, 'a notification');
      final (shownHost, alert) = notifier.shown.single;
      expect(shownHost.id, 'a');
      expect(alert.paneId, pane);
      expect(alert.status, AgentStatus.blocked);
      expect(alert.agent, 'claude');
      expect(alert.where, startsWith('api'));

      await report(pane, 'working');
      await until(() => notifier.cancelled.isNotEmpty, 'the cancel');
      expect(notifier.cancelled.single, ('a', pane));

      // herdr has no reported "done": an agent that stops working while
      // its pane is not focused is done.
      final other = await herdr.createWorkspace('other');
      await herdr.client.request('pane.focus', {'pane_id': other});
      await report(pane, 'working');
      await report(pane, 'idle');
      await until(() => notifier.shown.length == 2, 'the done notification');
      expect(notifier.shown.last.$2.status, AgentStatus.done);
    });

    test('a host whose server key is not trusted yet stops, and the '
        'others go on', () async {
      final pane = await herdr.createWorkspace('api');
      await report(pane, 'working');
      await hosts.save(host('a', '127.0.0.1'));
      // The same server under another name: its key is not trusted.
      await hosts.save(host('b', 'localhost'));
      await hub.reload();
      await until(
        () =>
            hub.summary.value ==
            'box-a: watching\nbox-b: stopped, open the host in the app',
        'one host live and one stopped',
      );
      expect(asked, 1);

      await report(pane, 'blocked');
      await until(() => notifier.shown.isNotEmpty, 'a notification');
      expect(notifier.shown.single.$1.id, 'a');

      // The user opens the host in the app and trusts its key: the next
      // reload brings the stopped watcher back, with notify unchanged.
      await knownHosts.trust('localhost', sshd.port, sshd.hostKey);
      await hub.reload();
      await until(
        () => hub.summary.value == 'box-a: watching\nbox-b: watching',
        'both hosts live',
      );
      await report(pane, 'working');
      await until(
        () => notifier.cancelled.contains(('b', pane)),
        'the host trusted since to see the agent work',
      );
      await report(pane, 'blocked');
      await until(
        () => notifier.shown.any((s) => s.$1.id == 'b'),
        'a notification from the host trusted since',
      );
    });

    test('turning notify off stops the watcher', () async {
      await hosts.save(host('a', '127.0.0.1'));
      await hub.reload();
      await until(() => hub.summary.value == 'box-a: watching', 'live');
      final h = host('a', '127.0.0.1');
      await hosts.save(
        Host(
          id: h.id,
          label: h.label,
          address: h.address,
          port: h.port,
          user: h.user,
          keyId: h.keyId,
          herdrSession: h.herdrSession,
        ),
      );
      await hub.reload();
      expect(hub.count, 0);
      expect(hub.summary.value, '');
    });
  });
}
