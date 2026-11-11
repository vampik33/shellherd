/// Runs [HerdrCache] against a real herdr server, and [HerdrConnection] over
/// a real SSH connection to a throwaway sshd on 127.0.0.1. Skipped when
/// `herdr` or `sshd` is missing.
@Tags(['herdr'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/herdr_cache.dart';
import 'package:shellherd/herdr/herdr_connection.dart';
import 'package:shellherd/ssh/host.dart';
import 'package:shellherd/ssh/json_file.dart';
import 'package:shellherd/ssh/key_store.dart';
import 'package:shellherd/ssh/known_hosts.dart';
import 'package:shellherd/ssh/ssh_connector.dart';

import '../support/herdr_test_session.dart';
import '../support/memory_secret_store.dart';
import '../support/poll.dart';
import '../support/test_sshd.dart';

Future<void> main() async {
  final herdrSkip = await HerdrTestSession.herdrAvailable()
      ? null
      : 'herdr is not on PATH';
  final skip = herdrSkip ?? (TestSshd.binary == null ? 'no sshd' : null);

  group('HerdrCache on real herdr', skip: herdrSkip ?? false, () {
    late HerdrTestSession herdr;
    late HerdrCache cache;
    late HerdrSnapshot latest;

    setUp(() async {
      herdr = await HerdrTestSession.start();
      cache = HerdrCache(
        herdr.client,
        onSnapshot: (s) => latest = s,
        debounce: const Duration(milliseconds: 20),
        refreshEvery: const Duration(milliseconds: 200),
      );
    });
    tearDown(() async {
      await cache.close();
      await herdr.stop();
    });

    Pane pane(String id) => latest.panes.firstWhere((p) => p.id == id);

    Future<void> report(String id, String state) => herdr.client.request(
      'pane.report_agent',
      {'pane_id': id, 'source': 'test', 'agent': 'claude', 'state': state},
    );

    test('a new workspace shows up', () async {
      await cache.start();
      await herdr.createWorkspace('fresh');
      await until(
        () => latest.workspaces.any((w) => w.label == 'fresh'),
        'the workspace',
      );
    });

    test('an agent status reaches the copy, also on a new pane', () async {
      final first = await herdr.createWorkspace('a');
      await cache.start();
      await report(first, 'working');
      await until(() => pane(first).status == AgentStatus.working, 'working');

      // A subscription made before this pane existed cannot cover it.
      final second = await herdr.createWorkspace('b');
      await until(() => latest.panes.any((p) => p.id == second), 'the pane');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await report(second, 'blocked');
      await until(() => pane(second).status == AgentStatus.blocked, 'blocked');
    });

    test('a pane that exits leaves, and the others still report', () async {
      final keep = await herdr.createWorkspace('keep');
      final gone = await herdr.createWorkspace('gone');
      await cache.start();
      await herdr.client.paneSendInput(gone, text: 'exit', keys: ['enter']);
      await until(() => latest.panes.every((p) => p.id != gone), 'the exit');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await report(keep, 'working');
      await until(() => pane(keep).status == AgentStatus.working, 'working');
    });

    test('a renamed workspace and pane show the new names', () async {
      final id = await herdr.createWorkspace('old');
      await cache.start();
      final ws = latest.panes.firstWhere((p) => p.id == id).workspaceId;
      await herdr.client.request('workspace.rename', {
        'workspace_id': ws,
        'label': 'renamed',
      });
      await until(
        () => latest.workspaces.any((w) => w.label == 'renamed'),
        'the workspace name',
      );
      await herdr.client.request('pane.rename', {
        'pane_id': id,
        'label': 'renamed pane',
      });
      // herdr sends no event for this; the periodic refresh brings it.
      await until(() => pane(id).label == 'renamed pane', 'the pane name');
    });

    test('a server that stops ends the cache', () async {
      await cache.start();
      final lost = cache.lost;
      await Process.run('herdr', ['--session', herdr.name, 'server', 'stop']);
      await lost.timeout(const Duration(seconds: 5));
    });
  });

  group('HerdrConnection over ssh', skip: skip ?? false, () {
    late HerdrTestSession herdr;
    late TestSshd sshd;
    late Directory dir;
    late HerdrConnection link;
    late Host host;
    late SshConnector connector;

    Host hostWith(String keyId, String session) => Host(
      id: 'h1',
      label: 'testbox',
      address: '127.0.0.1',
      port: sshd.port,
      user: Platform.environment['USER']!,
      keyId: keyId,
      herdrSession: session,
    );

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('shellherd-link-');
      herdr = await HerdrTestSession.start();
      sshd = await TestSshd.start();
      final keys = KeyStore(MemorySecretStore());
      final keyId = await keys.generate();
      await sshd.authorize(await keys.publicLine(keyId));
      final knownHosts = KnownHosts(
        JsonFile(File('${dir.path}/known_hosts.json')),
      );
      await knownHosts.trust('127.0.0.1', sshd.port, sshd.hostKey);
      connector = SshConnector(
        knownHosts: knownHosts,
        keys: keys,
        askTrust: (_, _) async => false,
        timeout: const Duration(seconds: 5),
      );
      host = hostWith(keyId, herdr.name);
      link = HerdrConnection(
        sshLinkOpener(connector, host, timeout: const Duration(seconds: 1)),
        refreshEvery: const Duration(milliseconds: 200),
        backoff: (_) => const Duration(milliseconds: 100),
        debounce: const Duration(milliseconds: 20),
      );
    });
    tearDown(() async {
      link.dispose();
      await sshd.signalConnections(ProcessSignal.sigcont).catchError((_) {});
      await sshd.stop();
      await herdr.stop();
      await dir.delete(recursive: true);
    });

    Future<void> live() => until(() => link.state.value is LinkLive, 'live');

    test('goes live and follows the session', () async {
      await herdr.createWorkspace('before');
      link.connect();
      await live();
      expect(
        link.snapshot.value!.workspaces.any((w) => w.label == 'before'),
        isTrue,
      );
      await herdr.createWorkspace('after');
      await until(
        () => link.snapshot.value!.workspaces.any((w) => w.label == 'after'),
        'the new workspace',
      );
    });

    test('a killed connection reconnects, and misses nothing', () async {
      link.connect();
      await live();
      await sshd.signalConnections(ProcessSignal.sigkill);
      await until(() => link.state.value is LinkReconnecting, 'the drop');
      // Made during the outage: the new snapshot has to show it.
      await herdr.createWorkspace('during');
      await live();
      await until(
        () => link.snapshot.value!.workspaces.any((w) => w.label == 'during'),
        'the workspace from the outage',
      );
    });

    test('a stalled connection is noticed by the refresh', () async {
      link.connect();
      await live();
      await sshd.signalConnections(ProcessSignal.sigstop);
      await until(
        () => link.state.value is LinkReconnecting,
        'the stall to show',
        within: const Duration(seconds: 5),
      );
      await sshd.signalConnections(ProcessSignal.sigcont);
      await live();
    });

    test('no herdr server, then one that starts', () async {
      link = HerdrConnection(
        sshLinkOpener(connector, hostWith(host.keyId!, 'shellherd-test-none')),
        backoff: (_) => const Duration(milliseconds: 100),
      );
      link.connect();
      await until(() => link.state.value is LinkNoServer, 'no server');
      link.dispose();

      link = HerdrConnection(sshLinkOpener(connector, host));
      link.connect();
      await live();
    });

    test('a server that stops shows no server', () async {
      link.connect();
      await live();
      await Process.run('herdr', ['--session', herdr.name, 'server', 'stop']);
      await until(() => link.state.value is LinkNoServer, 'no server');
    });

    test('a refused login stops in failed', () async {
      final other = KeyStore(MemorySecretStore());
      final bad = HerdrConnection(
        sshLinkOpener(
          SshConnector(
            knownHosts: connector.knownHosts,
            keys: other,
            askTrust: connector.askTrust,
            timeout: const Duration(seconds: 5),
          ),
          hostWith(await other.generate(), herdr.name),
        ),
      );
      addTearDown(bad.dispose);
      bad.connect();
      await until(() => bad.state.value is LinkFailed, 'failed');
      expect((bad.state.value as LinkFailed).cause, isA<SshAuthFailed>());
    });
  });
}
