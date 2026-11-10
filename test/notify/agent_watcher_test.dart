
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/herdr_connection.dart';
import 'package:shellherd/notify/agent_watcher.dart';
import 'package:shellherd/notify/notifier.dart';
import 'package:shellherd/notify/notify_control.dart';
import 'package:shellherd/notify/watch_hub.dart';
import 'package:shellherd/ssh/host.dart';
import 'package:shellherd/ssh/known_hosts.dart';
import 'package:shellherd/ssh/ssh_connector.dart';

import '../support/fake_herdr.dart';
import '../support/fake_snapshots.dart';
import '../support/poll.dart';
import '../support/recording_notifier.dart';

const _key = HostKey('ssh-ed25519', 'SHA256:x');

Host _host(String id, {bool notify = true, String? label}) => Host(
  id: id,
  label: label ?? 'box-$id',
  address: 'box',
  user: 'me',
  keyId: 'k',
  notify: notify,
);

/// A session with one workspace "api" and one agent per pane id.
Map<String, Object?> _session(Map<String, String> statuses) => fakeSnapshot(
  workspaces: [fakeWorkspace('w1', 1, 'api', 'idle')],
  tabs: [fakeTab('w1', 'main', 'idle')],
  panes: [
    for (final MapEntry(:key, :value) in statuses.entries)
      fakePane(key, 'w1', value, {'agent': 'claude'}),
  ],
  agents: [
    for (final MapEntry(:key, :value) in statuses.entries)
      fakeAgent(key, 'w1', value, {'agent': 'claude'}),
  ],
);

HerdrSnapshot _snap(Map<String, String> statuses) =>
    HerdrSnapshot.fromJson(_session(statuses));

/// A connection whose links come from [links], in order; each new link
/// serves the session of [session] at the time it opens.
class _Links {
  _Links(this.session);

  Map<String, String> session;
  final opened = <FakeLink>[];
  Object? failWith;

  HerdrConnection connection() => HerdrConnection(
    () async {
      if (failWith case final error?) throw error;
      final link = FakeLink(_session(session));
      opened.add(link);
      return link.open;
    },
    backoff: (_) => const Duration(milliseconds: 1),
    debounce: const Duration(milliseconds: 1),
    refreshEvery: const Duration(minutes: 1),
  );

  /// Changes the session on the open link and tells the watcher.
  void change(Map<String, String> statuses) {
    session = statuses;
    final herdr = opened.last.herdr;
    herdr.snapshotJson = _session(statuses);
    herdr.push('pane_agent_status_changed');
  }
}

/// What [n] showed, as (host id, pane id, status).
List<(String, String, AgentStatus)> _shown(RecordingNotifier n) => [
  for (final (host, alert) in n.shown) (host.id, alert.paneId, alert.status),
];

void main() {
  group('agentChanges', () {
    test('alerts on a change into blocked or done, with names', () {
      final c = agentChanges(
        {'w1:p1': AgentStatus.working, 'w1:p2': AgentStatus.idle},
        _snap({'w1:p1': 'blocked', 'w1:p2': 'done'}),
      );
      expect(c.cancel, isEmpty);
      expect(
        [for (final a in c.show) (a.paneId, a.status, a.agent, a.where)],
        [
          ('w1:p1', AgentStatus.blocked, 'claude', 'api › main'),
          ('w1:p2', AgentStatus.done, 'claude', 'api › main'),
        ],
      );
    });

    test('does not alert again for the same status', () {
      final c = agentChanges({
        'w1:p1': AgentStatus.blocked,
      }, _snap({'w1:p1': 'blocked'}));
      expect(c.show, isEmpty);
      expect(c.cancel, isEmpty);
    });

    test('alerts on blocked to done, which replaces the notification', () {
      final c = agentChanges({
        'w1:p1': AgentStatus.blocked,
      }, _snap({'w1:p1': 'done'}));
      expect([for (final a in c.show) a.status], [AgentStatus.done]);
      expect(c.cancel, isEmpty);
    });

    test('takes the notification back when the agent moves on or goes', () {
      final c = agentChanges(
        {
          'w1:p1': AgentStatus.blocked,
          'w1:p2': AgentStatus.done,
          'w1:p3': AgentStatus.working,
        },
        _snap({'w1:p1': 'working'}),
      );
      expect(c.show, isEmpty);
      expect(c.cancel, unorderedEquals(['w1:p1', 'w1:p2']));
    });

    test('ignores idle, working and unknown', () {
      final c = agentChanges(
        {},
        _snap({'w1:p1': 'idle', 'w1:p2': 'working', 'w1:p3': 'unknown'}),
      );
      expect(c.show, isEmpty);
    });

    test('a missing workspace or tab leaves only what is known', () {
      final s = HerdrSnapshot.fromJson(
        fakeSnapshot(
          agents: [
            fakeAgent('w9:p1', 'w9', 'blocked', {'name': 'reviewer'}),
          ],
        ),
      );
      final alert = agentChanges({}, s).show.single;
      expect(alert.agent, 'reviewer');
      expect(alert.where, '');
    });
  });

  group('AgentWatcher', () {
    late _Links links;
    late RecordingNotifier notifier;
    late AgentWatcher watcher;

    setUp(() {
      links = _Links({'w1:p1': 'working'});
      notifier = RecordingNotifier();
      watcher = AgentWatcher(
        _host('h'),
        links.connection(),
        notifier: notifier,
        noServerRetry: const Duration(milliseconds: 20),
      )..start();
    });
    tearDown(() => watcher.dispose());

    Future<void> live() => until(
      () => watcher.connection.state.value is LinkLive,
      'the watcher to go live',
    );

    test('the first snapshot does not notify', () async {
      watcher.dispose();
      links = _Links({'w1:p1': 'blocked'});
      watcher = AgentWatcher(
        _host('h'),
        links.connection(),
        notifier: notifier,
      )..start();
      await live();
      expect(notifier.shown, isEmpty);
    });

    test('notifies once when an agent becomes blocked', () async {
      await live();
      links.change({'w1:p1': 'blocked'});
      await until(() => notifier.shown.isNotEmpty, 'a notification');
      // Another event with the same status.
      links.opened.last.herdr.push('pane_agent_status_changed');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(_shown(notifier), [('h', 'w1:p1', AgentStatus.blocked)]);
    });

    test('takes the notification back when the agent works again', () async {
      await live();
      links.change({'w1:p1': 'blocked'});
      await until(() => notifier.shown.isNotEmpty, 'a notification');
      links.change({'w1:p1': 'working'});
      await until(() => notifier.cancelled.isNotEmpty, 'a cancel');
      expect(notifier.cancelled, [('h', 'w1:p1')]);
    });

    test('the pane on the screen does not notify, and its notification '
        'goes', () async {
      await live();
      watcher.shownPane = 'w1:p1';
      expect(notifier.cancelled, [('h', 'w1:p1')]);
      links.change({'w1:p1': 'blocked', 'w1:p2': 'done'});
      await until(() => notifier.shown.isNotEmpty, 'a notification');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(_shown(notifier), [('h', 'w1:p2', AgentStatus.done)]);

      watcher.shownPane = null;
      links.change({'w1:p1': 'done', 'w1:p2': 'done'});
      await until(() => notifier.shown.length == 2, 'a second notification');
      expect(_shown(notifier).last, ('h', 'w1:p1', AgentStatus.done));
    });

    test('a change while the link was down notifies once it is back, and '
        'nothing repeats', () async {
      await live();
      links.change({'w1:p1': 'blocked'});
      await until(() => notifier.shown.length == 1, 'a notification');
      // The link drops; on the PC one agent finishes meanwhile.
      links.session = {'w1:p1': 'blocked', 'w1:p2': 'done'};
      links.opened.last.open.close();
      await until(() => links.opened.length == 2, 'a new link');
      await live();
      await until(() => notifier.shown.length == 2, 'the missed change');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(_shown(notifier), [
        ('h', 'w1:p1', AgentStatus.blocked),
        ('h', 'w1:p2', AgentStatus.done),
      ]);
    });

    test('looks again for a herdr server that was not running', () async {
      await live();
      links.failWith = HerdrConnectException(
        'ping',
        SSHChannelOpenError(2, 'x'),
      );
      links.opened.last.open.close();
      await until(
        () => watcher.connection.state.value is LinkNoServer,
        'no server',
      );
      links.failWith = null;
      await live();
      expect(links.opened, hasLength(2));
    });
  });

  group('WatchHub', () {
    late List<Host> hosts;
    late RecordingNotifier notifier;
    late List<HerdrConnection> connections;
    late WatchHub hub;
    late Object? loadError;

    setUp(() {
      hosts = [_host('a'), _host('b', notify: false)];
      notifier = RecordingNotifier();
      connections = [];
      loadError = null;
      hub = WatchHub(
        loadHosts: () async {
          if (loadError case final e?) throw e;
          return hosts;
        },
        connect: (host) {
          final c = _Links({'w1:p1': 'working'}).connection();
          connections.add(c);
          return c;
        },
        notifier: notifier,
      );
    });
    tearDown(() => hub.dispose());

    test('watches only the hosts with notify on', () async {
      await hub.reload();
      expect(hub.count, 1);
      expect(connections, hasLength(1));
    });

    test('keeps a watcher whose host did not change, restarts a changed '
        'one, and stops a removed one', () async {
      await hub.reload();
      final first = connections.single;
      await hub.reload();
      expect(connections, [first]);

      hosts = [_host('a', label: 'renamed'), _host('b')];
      await hub.reload();
      expect(hub.count, 2);
      expect(connections, hasLength(3));
      // The old connection is disposed.
      expect(() => first.state.addListener(() {}), throwsFlutterError);

      hosts = [];
      await hub.reload();
      expect(hub.count, 0);
    });

    test('a kept watcher that stopped tries again on reload', () async {
      var refuse = true;
      hub = WatchHub(
        loadHosts: () async => hosts,
        connect: (host) {
          final links = _Links({'w1:p1': 'working'});
          final c = HerdrConnection(
            () async {
              if (refuse) throw SshHostKeyRejected(host, _key);
              final link = FakeLink(_session(links.session));
              return link.open;
            },
            backoff: (_) => const Duration(milliseconds: 1),
            debounce: const Duration(milliseconds: 1),
          );
          connections.add(c);
          return c;
        },
        notifier: notifier,
      );
      await hub.reload();
      final c = connections.single;
      await until(() => c.state.value is LinkFailed, 'the stop');
      refuse = false;
      await hub.reload();
      expect(connections, [c], reason: 'the same watcher');
      await until(() => c.state.value is LinkLive, 'live again');
    });

    test('a failed read of the hosts does not stop the next reload', () async {
      loadError = StateError('broken file');
      await expectLater(hub.reload(), throwsStateError);
      loadError = null;
      await hub.reload();
      expect(hub.count, 1);
    });

    test('says how each host is', () async {
      await hub.reload();
      await until(
        () => hub.summary.value == 'box-a: watching',
        'the summary to say watching',
      );
    });

    test('passes the pane on the screen to its host, also to a watcher that '
        'starts later', () async {
      hub.shown = const PaneTarget('b', 'w1:p1');
      hosts = [_host('a'), _host('b')];
      await hub.reload();
      expect(notifier.cancelled, [('b', 'w1:p1')]);
    });
  });

  group('nextShown', () {
    const a = PaneTarget('h', 'w1:p1');
    const b = PaneTarget('h', 'w1:p2');

    test('a pane that comes is shown', () {
      expect(nextShown(null, a, true), a);
      expect(nextShown(a, b, true), b);
    });

    test('a pane that goes clears only itself', () {
      expect(nextShown(a, a, false), isNull);
      // The old screen goes after the new one came.
      expect(nextShown(b, a, false), b);
    });
  });

  group('notifications', () {
    test('ids are fixed, 31 bits, and differ by host and pane', () {
      final id = notificationId('h', 'w1:p1');
      expect(id, notificationId('h', 'w1:p1'));
      expect(id, isNot(notificationId('h', 'w1:p2')));
      expect(id, isNot(notificationId('g', 'w1:p1')));
      expect(id, inInclusiveRange(0, 0x7fffffff));
      // FNV-1a of "h/w1:p1", so that it cannot change between releases.
      expect(id, 0x7382172d);
    });

    test('a target goes through the payload and back', () {
      const target = PaneTarget('0a1b', 'w1:p2');
      expect(PaneTarget.decode(target.encode()), target);
      expect(PaneTarget.decode(null), isNull);
      expect(PaneTarget.decode('not json'), isNull);
      expect(PaneTarget.decode('[1, 2]'), isNull);
    });

    test('the text names the agent, the host and the place', () {
      const alert = AgentAlert(
        paneId: 'w1:p1',
        status: AgentStatus.blocked,
        agent: 'claude',
        where: 'api › main',
      );
      expect(alertText(_host('h', label: 'workbox'), alert), (
        title: 'claude needs you',
        body: 'workbox · api › main',
      ));
      final done = AgentAlert(
        paneId: 'w1:p1',
        status: AgentStatus.done,
        agent: 'codex',
        where: '',
      );
      expect(alertText(_host('h', label: 'workbox'), done), (
        title: 'codex is done',
        body: 'workbox',
      ));
    });
  });

  test('a stale timer does not survive dispose', () async {
    final links = _Links({})
      ..failWith = HerdrConnectException('ping', SSHChannelOpenError(2, 'x'));
    final watcher = AgentWatcher(
      _host('h'),
      links.connection(),
      notifier: RecordingNotifier(),
      noServerRetry: const Duration(milliseconds: 10),
    )..start();
    await until(
      () => watcher.connection.state.value is LinkNoServer,
      'no server',
    );
    watcher.dispose();
    // A retry after dispose would throw on the disposed connection.
    await Future<void>.delayed(const Duration(milliseconds: 40));
  });
}
