/// Runs [PaneStream] over `herdr terminal session observe` on a real SSH
/// connection to a throwaway sshd on 127.0.0.1, against a real herdr server
/// in a throwaway named session. Skipped when `herdr` or `sshd` is missing.
/// Run alone with: flutter test test/herdr/pane_stream_live_test.dart
@Tags(['herdr', 'sshd'])
library;

import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/herdr_cache.dart';
import 'package:shellherd/herdr/herdr_link.dart';
import 'package:shellherd/herdr/pane_stream.dart';

import '../support/herdr_test_session.dart';
import '../support/poll.dart';
import '../support/test_sshd.dart';

/// The pids of `herdr terminal session observe` processes that talk to the
/// server at [socketPath]: only this test's, not those of the user's own
/// herdr.
Future<List<int>> _observers(String socketPath) async {
  final found = <int>[];
  for (final dir in Directory('/proc').listSync().whereType<Directory>()) {
    final pid = int.tryParse(dir.uri.pathSegments.lastWhere((s) => s.isNotEmpty));
    if (pid == null) continue;
    try {
      final args = File('${dir.path}/cmdline').readAsStringSync().split('\x00');
      if (!args.contains('observe') || !args.contains('session')) continue;
      final env = File('${dir.path}/environ').readAsStringSync().split('\x00');
      if (env.contains('HERDR_SOCKET_PATH=$socketPath')) found.add(pid);
    } on FileSystemException {
      // Gone, or not ours to read.
    }
  }
  return found;
}

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
  late ScreenOpener opener;
  HerdrTestSession? startedHerdr;
  TestSshd? startedSshd;
  SSHClient? openSsh;

  setUpAll(() async {
    if (skip != null) return;
    await Future.wait([
      HerdrTestSession.start().then((h) => herdr = startedHerdr = h),
      TestSshd.start().then((s) => sshd = startedSshd = s),
    ]);
    ssh = openSsh = await sshd.connect();
    link = await HerdrLink.connect(ssh, session: herdr.name);
    opener = sshScreenOpener(ssh, link.socketPath);
  });
  tearDownAll(() async {
    openSsh?.close();
    await startedSshd?.stop();
    await startedHerdr?.stop();
  });

  group('PaneStream over ssh', skip: skip ?? false, () {
    late ValueNotifier<int> changes;
    final streams = <PaneStream>[];

    setUp(() => changes = ValueNotifier(0));
    tearDown(() {
      for (final s in streams) {
        s.dispose();
      }
      streams.clear();
      changes.dispose();
    });

    Future<PaneSize> sizeOf(String paneId) async =>
        (await herdr.client.snapshot()).paneSizes[paneId]!;

    PaneStream stream(String paneId, PaneSize size, {ScreenOpener? via}) {
      final s = PaneStream(
        () => via ?? opener,
        paneId,
        () => size,
        changes: changes,
      )..running = true;
      streams.add(s);
      return s;
    }

    List<String> rows(PaneStream s) =>
        (s.view.value.text ?? '')
            .replaceAll(RegExp(r'\x1b\[[0-9;]*m'), '')
            .split('\n')
            .map((l) => l.trimRight())
            .toList();

    test('shows the pane at its size and its changes as they come', () async {
      final paneId = await herdr.createWorkspace('stream');
      final size = await sizeOf(paneId);
      final s = stream(paneId, size);
      await until(() => rows(s).any((r) => r.contains(r'$')), 'the prompt');
      expect(rows(s), hasLength(size.rows));

      // More lines than rows: the bottom of the screen must be in view.
      final sent = Stopwatch()..start();
      await herdr.client.paneSendInput(
        paneId,
        text: 'seq 1 ${size.rows + 20}',
        keys: const ['enter'],
      );
      await until(
        () => rows(s).contains('${size.rows + 20}'),
        'the last number',
      );
      debugPrint('pane output on the phone after ${sent.elapsedMilliseconds} ms');
      await until(
        () => rows(s).lastWhere((r) => r.isNotEmpty).endsWith(r'$'),
        'the prompt on the bottom row',
      );
      expect(s.unavailable.value, isFalse);
    });

    test('closing the stream stops herdr on the remote host', () async {
      final paneId = await herdr.createWorkspace('stop');
      final s = stream(paneId, await sizeOf(paneId));
      await until(() => s.view.value.text != null, 'the first frame');
      expect(await _observers(link.socketPath), isNotEmpty);
      s.running = false;
      // The pane prints nothing, so only the end of stdin stops herdr.
      await eventually(
        () async => (await _observers(link.socketPath)).isEmpty,
        'no observer left',
      );
    });

    test('a pane that closes ends the stream as gone', () async {
      final paneId = await herdr.createWorkspace('closing');
      final s = stream(paneId, await sizeOf(paneId));
      await until(() => s.view.value.text != null, 'the first frame');
      await herdr.client.request('pane.close', {'pane_id': paneId});
      await until(() => s.view.value.gone, 'gone');
      expect(s.unavailable.value, isFalse);
    });

    test('an unknown pane is gone at once', () async {
      final s = stream('w999:p999', const PaneSize(20, 5));
      await until(() => s.view.value.gone, 'gone');
    });

    test('a socket where no herdr listens makes it unavailable', () async {
      final paneId = await herdr.createWorkspace('nowhere');
      final s = stream(
        paneId,
        await sizeOf(paneId),
        via: sshScreenOpener(ssh, '${link.socketPath}.missing'),
      );
      await until(() => s.unavailable.value, 'unavailable');
      expect(s.view.value.text, isNull);
    });

    test('the cache follows a new pane size', () async {
      final paneId = await herdr.createWorkspace('split');
      final before = await sizeOf(paneId);
      final sizes = <PaneSize?>[];
      final cache = HerdrCache(
        link.client,
        onSnapshot: (snap) => sizes.add(snap.paneSizes[paneId]),
        debounce: const Duration(milliseconds: 20),
        refreshEvery: const Duration(minutes: 10),
      );
      addTearDown(cache.close);
      await cache.start();
      expect(sizes.last, before);
      await herdr.client.request('pane.split', {
        'target_pane_id': paneId,
        'direction': 'right',
      });
      await until(
        () => sizes.last != null && sizes.last!.cols < before.cols,
        'the narrower size',
      );
    });
  });
}
