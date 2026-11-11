import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/herdr_connection.dart';
import 'package:shellherd/ssh/host.dart';
import 'package:shellherd/ssh/known_hosts.dart';
import 'package:shellherd/ssh/ssh_connector.dart';

import '../support/fake_herdr.dart';
import '../support/poll.dart';

const _settle = Duration(milliseconds: 30);
final _host = Host(
  id: 'h',
  label: 'box',
  address: 'box',
  port: 22,
  user: 'me',
  keyId: 'k',
);
const _key = HostKey('ssh-ed25519', 'SHA256:x');

void main() {
  late List<FutureOr<FakeLink> Function()> script;
  late List<FakeLink> links;
  late int opens;
  late HerdrConnection link;
  late List<LinkState> states;

  void build({Duration refreshEvery = const Duration(minutes: 1)}) {
    link = HerdrConnection(
      () async {
        opens++;
        final next = await (script.isNotEmpty
            ? script.removeAt(0)
            : FakeLink.new)();
        links.add(next);
        return next.open;
      },
      refreshEvery: refreshEvery,
      backoff: (failures) => Duration(milliseconds: 1 + failures),
      debounce: const Duration(milliseconds: 1),
    );
    link.state.addListener(() => states.add(link.state.value));
  }

  FakeLink Function() fails(Object error) =>
      () => throw error;

  Future<void> live() =>
      until(() => link.state.value is LinkLive, 'the link to go live');

  setUp(() {
    script = [];
    links = [];
    opens = 0;
    states = [];
    build();
  });
  tearDown(() => link.dispose());

  group('HerdrConnection', () {
    test('goes through connecting and syncing to live', () async {
      link.connect();
      await live();
      expect(states.map((s) => s.runtimeType), [
        LinkConnecting,
        LinkSyncing,
        LinkLive,
      ]);
      expect((states.last as LinkLive).server.protocol, 22);
      expect(link.snapshot.value, isNotNull);
    });

    test('an event updates the snapshot', () async {
      link.connect();
      await live();
      final before = link.snapshot.value;
      links.single.herdr.push();
      await until(() => link.snapshot.value != before, 'a new snapshot');
    });

    test('the pane api exists only while the link is live', () async {
      expect(link.api, isNull);
      link.connect();
      await live();
      expect(link.api, same(links.single.open.api));

      final next = Completer<FakeLink>();
      script.add(() => next.future);
      links.single.done.complete();
      await until(() => opens == 2, 'the next attempt');
      expect(link.api, isNull);

      next.complete(FakeLink());
      await live();
      expect(link.api, same(links.last.open.api));

      link.close();
      expect(link.api, isNull);
    });

    test('a second connect while live does nothing', () async {
      link.connect();
      await live();
      link.connect();
      await Future<void>.delayed(_settle);
      expect(opens, 1);
    });

    test('a dropped link reconnects and keeps the snapshot', () async {
      link.connect();
      await live();
      final before = link.snapshot.value;
      links.single.done.complete();
      await until(() => opens == 2 && link.state.value is LinkLive, 'return');
      expect(states.whereType<LinkReconnecting>(), isNotEmpty);
      expect(before, isNotNull);
      expect(links.first.closed, isTrue);
      expect(links.first.herdr.subscriptions.single.closed, isTrue);
    });

    test('the snapshot stays while the link is down', () async {
      link = HerdrConnection(() async {
        opens++;
        if (opens > 1) throw const HerdrConnectionClosedException('down');
        final l = FakeLink();
        links.add(l);
        return l.open;
      }, backoff: (_) => const Duration(minutes: 1));
      link.connect();
      await until(() => link.state.value is LinkLive, 'live');
      final kept = link.snapshot.value;
      links.single.done.complete();
      await until(() => link.state.value is LinkReconnecting, 'the drop');
      expect(link.snapshot.value, same(kept));
    });

    test('a lost subscription reconnects', () async {
      link.connect();
      await live();
      links.single.herdr.subscriptions.single.reply({
        'error': {'code': 'events_lost', 'message': 'slow'},
      });
      await until(() => opens == 2 && link.state.value is LinkLive, 'return');
    });

    test(
      'a refresh that fails reconnects: this finds a stalled link',
      () async {
        build(refreshEvery: const Duration(milliseconds: 2));
        link.connect();
        await live();
        links.single.herdr.errors['session.snapshot'] = ['internal'];
        await until(() => opens == 2, 'a new link after the failed refresh');
      },
    );

    test('an event this build cannot read stops, without a retry', () async {
      link.connect();
      await live();
      links.single.herdr.subscriptions.single.reply({'event': 1, 'data': {}});
      await until(() => link.state.value is LinkFailed, 'failed');
      expect((states.last as LinkFailed).cause, isA<HerdrProtocolException>());
      await Future<void>.delayed(_settle);
      expect(opens, 1);
    });

    test('a whole line that is not JSON stops, without a retry', () async {
      link.connect();
      await live();
      links.single.herdr.subscriptions.single.replyRaw(
        utf8.encode('not json\n'),
      );
      await until(() => link.state.value is LinkFailed, 'failed');
      await Future<void>.delayed(_settle);
      expect(opens, 1);
    });

    test('an event line cut off by a drop reconnects', () async {
      link.connect();
      await live();
      links.single.herdr.subscriptions.single
        ..replyRaw(utf8.encode('{"event":"pane_cre'))
        ..end();
      await until(() => opens == 2 && link.state.value is LinkLive, 'return');
      expect(states.whereType<LinkFailed>(), isEmpty);
    });

    test('a snapshot reply cut off by a drop reconnects', () async {
      final bad = FakeLink();
      bad.herdr.torn.add('session.snapshot');
      script.add(() => bad);
      link.connect();
      await until(() => opens == 2 && link.state.value is LinkLive, 'return');
      expect(states.whereType<LinkFailed>(), isEmpty);
    });

    test('close stops the refreshes', () async {
      build(refreshEvery: const Duration(milliseconds: 2));
      link.connect();
      await live();
      final herdr = links.single.herdr;
      await until(() => herdr.count('session.snapshot') >= 4, 'refreshes');
      link.close();
      await until(() => links.single.closed, 'the link to close');
      final after = herdr.count('session.snapshot');
      await Future<void>.delayed(_settle);
      expect(herdr.count('session.snapshot'), after);
    });

    test('a network failure on the first attempt retries', () async {
      script.add(fails(SshNetworkException(_host, 'no route')));
      link.connect();
      await live();
      expect(opens, 2);
      expect(states[1], isA<LinkReconnecting>());
      expect((states[1] as LinkReconnecting).retryAt, isNotNull);
      expect(states[2], isA<LinkReconnecting>());
      expect((states[2] as LinkReconnecting).retryAt, isNull);
    });

    test('the wait grows, and live resets it', () async {
      final waits = <int>[];
      var fail = 3;
      link = HerdrConnection(
        () async {
          if (fail-- > 0) throw SshNetworkException(_host, 'down');
          final l = FakeLink();
          links.add(l);
          return l.open;
        },
        backoff: (failures) {
          waits.add(failures);
          return Duration.zero;
        },
        debounce: const Duration(milliseconds: 1),
      );
      link.connect();
      await live();
      expect(waits, [0, 1, 2]);
      links.single.done.complete();
      await until(() => waits.length == 4, 'the next wait');
      expect(waits.last, 0);
    });

    test('backoff: doubles, and stops at 30 s', () {
      expect(
        [for (var i = 0; i < 8; i++) linkBackoff(i).inSeconds],
        [1, 2, 4, 8, 16, 30, 30, 30],
      );
    });

    test('connect during a wait retries at once', () async {
      link = HerdrConnection(
        () async {
          opens++;
          if (opens == 1) throw SshNetworkException(_host, 'down');
          return (FakeLink()..herdr).open;
        },
        backoff: (_) => const Duration(minutes: 5),
        debounce: const Duration(milliseconds: 1),
      );
      link.connect();
      await until(
        () => switch (link.state.value) {
          LinkReconnecting(retryAt: _?) => true,
          _ => false,
        },
        'the wait',
      );
      link.connect();
      await live();
    });

    for (final (name, error) in <(String, Object)>[
      ('changed key', SshHostKeyChanged(_host, _key, _key)),
      ('declined key', SshHostKeyRejected(_host, _key)),
      ('refused login', SshAuthFailed(_host, 'no')),
      (
        'unapproved Tailscale check',
        SshTailscaleCheckNeeded(_host, Uri.parse('https://login.example/a')),
      ),
      ('unreadable reply', const HerdrProtocolException('bad')),
    ]) {
      test('$name stops and does not retry', () async {
        script.add(fails(error));
        link.connect();
        await until(() => link.state.value is LinkFailed, 'failed');
        expect((link.state.value as LinkFailed).cause, same(error));
        await Future<void>.delayed(_settle);
        expect(opens, 1);
      });
    }

    test('connect after a failure tries again', () async {
      script.add(fails(SshAuthFailed(_host, 'no')));
      link.connect();
      await until(() => link.state.value is LinkFailed, 'failed');
      link.connect();
      await live();
    });

    test('a closed socket is no server, and it does not retry', () async {
      final error = HerdrConnectException('ping', SSHChannelOpenError(2, 'x'));
      script.add(fails(error));
      link.connect();
      await until(() => link.state.value is LinkNoServer, 'no server');
      await Future<void>.delayed(_settle);
      expect(opens, 1);
      link.connect();
      await live();
    });

    test('a connect error with another cause retries', () async {
      script.add(fails(const HerdrConnectException('ping', 'link gone')));
      link.connect();
      await live();
      expect(opens, 2);
    });

    test('a sync failure closes that link and retries', () async {
      final bad = FakeLink();
      bad.herdr.errors['session.snapshot'] = ['internal'];
      script.add(() => bad);
      link.connect();
      await until(() => opens == 2 && link.state.value is LinkLive, 'return');
      expect(bad.closed, isTrue);
    });

    test('a drop that leads to no server stops there', () async {
      link.connect();
      await live();
      script.add(
        fails(HerdrConnectException('ping', SSHChannelOpenError(2, 'x'))),
      );
      links.single.done.complete();
      await until(() => link.state.value is LinkNoServer, 'no server');
    });

    test('close goes offline and drops the link', () async {
      link.connect();
      await live();
      final kept = link.snapshot.value;
      link.close();
      expect(link.state.value, isA<LinkOffline>());
      await until(() => links.single.closed, 'the link to close');
      expect(links.single.herdr.subscriptions.single.closed, isTrue);
      await Future<void>.delayed(_settle);
      expect(opens, 1);
      expect(link.state.value, isA<LinkOffline>());
      expect(link.snapshot.value, same(kept));
    });

    test('close during a wait stops the retries', () async {
      link = HerdrConnection(() async {
        opens++;
        throw SshNetworkException(_host, 'down');
      }, backoff: (_) => const Duration(milliseconds: 5));
      link.connect();
      await until(() => link.state.value is LinkReconnecting, 'the wait');
      link.close();
      final after = opens;
      await Future<void>.delayed(_settle);
      expect(opens, after);
      expect(link.state.value, isA<LinkOffline>());
    });

    test('a link that opens after close is closed', () async {
      final slow = Completer<FakeLink>();
      script.add(() => slow.future);
      link.connect();
      await until(() => opens == 1, 'the open');
      link.close();
      final late = FakeLink();
      slow.complete(late);
      await until(() => late.closed, 'the late link to close');
      expect(link.state.value, isA<LinkOffline>());
    });

    test('a slow open from before close leaves a new run alone', () async {
      final slow = Completer<FakeLink>();
      script.add(() => slow.future);
      link.connect();
      await until(() => opens == 1, 'the open');
      link.close();
      link.connect();
      await live();
      final old = FakeLink();
      slow.complete(old);
      await until(() => old.closed, 'the old link to close');
      expect(link.state.value, isA<LinkLive>());
      expect(links.where((l) => !l.closed), hasLength(1));
    });

    test('a sync in flight at close publishes nothing', () async {
      final held = FakeLink();
      held.herdr.holdSnapshots = Completer();
      script.add(() => held);
      link.connect();
      await until(() => held.herdr.count('session.snapshot') >= 1, 'the read');
      link.close();
      held.herdr.holdSnapshots!.complete();
      await until(() => held.closed, 'the link to close');
      expect(link.snapshot.value, isNull);
      expect(link.state.value, isA<LinkOffline>());
    });

    test('dispose stops everything', () async {
      link.connect();
      await live();
      final open = links.single;
      link.dispose();
      await until(() => open.closed, 'the link to close');
      link = HerdrConnection(() async => FakeLink().open); // for tearDown
    });
  });
}
