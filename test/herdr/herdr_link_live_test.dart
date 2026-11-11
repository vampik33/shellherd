/// Runs [HerdrLink] over a real SSH connection to a throwaway sshd on
/// 127.0.0.1, against a real herdr server in a throwaway named session.
/// Skipped when `herdr` or `sshd` is missing.
/// Run alone with: flutter test test/herdr/herdr_link_live_test.dart
@Tags(['herdr'])
library;

import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/herdr_link.dart';

import '../support/herdr_test_session.dart';
import '../support/test_sshd.dart';

Future<void> main() async {
  final skip = !await HerdrTestSession.herdrAvailable()
      ? 'herdr is not on PATH'
      : TestSshd.binary == null
      ? 'sshd is not installed'
      : null;

  late HerdrTestSession herdr;
  late TestSshd sshd;
  late SSHClient ssh;
  late HerdrLink link;
  HerdrTestSession? startedHerdr;
  TestSshd? startedSshd;
  SSHClient? openSsh;

  setUpAll(() async {
    if (skip != null) return;
    // Independent: start both at once. Each assigns its started* slot, so
    // tearDownAll stops whichever one came up if the other fails.
    await Future.wait([
      HerdrTestSession.start().then((h) => herdr = startedHerdr = h),
      TestSshd.start().then((s) => sshd = startedSshd = s),
    ]);
    ssh = openSsh = await sshd.connect();
    link = await HerdrLink.connect(ssh, session: herdr.name);
  });
  tearDownAll(() async {
    openSsh?.close();
    await startedSshd?.stop();
    await startedHerdr?.stop();
  });

  /// A second SSH connection with its own link, for tests that break it.
  /// The caller closes the returned [SSHClient].
  Future<(SSHClient, HerdrLink)> extraLink({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final other = await sshd.connect();
    return (
      other,
      await HerdrLink.connect(other, session: herdr.name, timeout: timeout),
    );
  }

  Matcher timeoutIn(String method) => throwsA(
    isA<HerdrTimeoutException>().having((e) => e.method, 'method', method),
  );

  group('HerdrLink over ssh', skip: skip ?? false, () {
    test('finds the session socket through the remote shell', () {
      // Same path the local herdr uses: the remote host is this machine.
      expect(link.socketPath, herdr.socketPath);
      expect(link.server.protocol, 22);
    });

    test('many requests share one SSH connection', () async {
      for (var i = 0; i < 5; i++) {
        await link.client.ping();
      }
      final pongs = await Future.wait(
        List.generate(10, (_) => link.client.ping()),
      );
      expect(pongs.map((p) => p.protocol), everyElement(22));
      expect(await link.client.snapshot(), isA<HerdrSnapshot>());
    });

    test('send_input then pane.read round trip', () async {
      final paneId = await herdr.createWorkspace('ssh-io');
      await link.client.paneSendInput(
        paneId,
        text: r'echo SSH_$((6*7))',
        keys: ['enter'],
      );
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      var text = '';
      while (!text.contains('SSH_42') && DateTime.now().isBefore(deadline)) {
        text = (await link.client.paneRead(paneId, lines: 50)).text;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(text, contains('SSH_42'));
    });

    test('a subscription gets events while requests run beside it', () async {
      final sub = await link.client.subscribe([
        const Subscription.lifecycle('workspace.created'),
      ]);
      final events = StreamIterator(sub.events);
      // Requests on other channels while the subscription channel is open.
      await link.client.ping();
      await link.client.request('workspace.create', {
        'cwd': Directory.systemTemp.path,
        'label': 'ssh-events',
        'focus': false,
      });
      HerdrEvent? created;
      while (created == null &&
          await events.moveNext().timeout(const Duration(seconds: 10))) {
        if (events.current.kind == 'workspace_created') {
          created = events.current;
        }
      }
      expect(created, isNotNull);
      // Must return although herdr keeps the subscription channel open.
      await events.cancel().timeout(const Duration(seconds: 5));
      expect((await link.client.ping()).protocol, 22);
    });

    test('a pane error comes back as HerdrApiException', () async {
      await expectLater(
        link.client.paneRead('no-such-pane'),
        throwsA(
          isA<HerdrApiException>().having(
            (e) => e.code,
            'code',
            'pane_not_found',
          ),
        ),
      );
    });

    test('no herdr server: connect fails with a channel open error', () async {
      await expectLater(
        HerdrLink.connect(ssh, session: 'shellherd-test-no-such-session'),
        throwsA(
          isA<HerdrNoSocketException>()
              .having((e) => e.cause, 'cause', isA<SSHChannelOpenError>())
              .having(
                (e) => '$e',
                'text',
                matches(
                  RegExp(
                    r'^herdr socket not found at /\S+/herdr/sessions/'
                    r'shellherd-test-no-such-session/herdr\.sock$',
                  ),
                ),
              ),
        ),
      );
      // The failed channel does not break the SSH connection.
      expect((await link.client.ping()).protocol, 22);
    });

    test('a dropped SSH connection ends an open subscription', () async {
      final (other, otherLink) = await extraLink();
      final sub = await otherLink.client.subscribe([
        const Subscription.lifecycle('workspace.created'),
      ]);
      final ended = Completer<void>();
      sub.events.listen((_) {}, onError: (_) {}, onDone: ended.complete);
      other.close();
      await ended.future.timeout(const Duration(seconds: 5));
    });

    test('a stalled SSH connection times out instead of hanging', () async {
      const timeout = Duration(seconds: 1);
      final (other, otherLink) = await extraLink(timeout: timeout);
      await sshd.signalConnections(ProcessSignal.sigstop);
      try {
        // The outer timeout only stops a hang: without the fix it fires
        // with a plain TimeoutException and the matcher fails.
        await expectLater(
          otherLink.client.ping().timeout(const Duration(seconds: 5)),
          timeoutIn('ping'),
        );
        await expectLater(
          HerdrLink.connect(
            other,
            session: herdr.name,
            timeout: timeout,
          ).timeout(const Duration(seconds: 5)),
          timeoutIn('config dir lookup'),
        );
      } finally {
        await sshd.signalConnections(ProcessSignal.sigcont);
        other.close();
      }
      // The stall stopped the shared connection too; it works again.
      expect((await link.client.ping()).protocol, 22);
    });

    test('a dropped SSH connection fails requests, it does not hang', () async {
      final (other, otherLink) = await extraLink();
      other.close();
      await other.done;
      await expectLater(
        otherLink.client.ping().timeout(const Duration(seconds: 5)),
        throwsA(isA<HerdrConnectException>()),
      );
    });
  });
}
