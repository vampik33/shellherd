import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/pane_poller.dart';
import 'package:shellherd/herdr/server_api.dart';

import '../support/fake_herdr.dart';
import '../support/poll.dart';

const _settle = Duration(milliseconds: 40);

void main() {
  late FakeHerdr herdr;
  HerdrClient? client;
  late PanePoller poller;

  PaneApi? api() => switch (client) {
    final c? => HerdrPaneApi(c),
    null => null,
  };

  PanePoller build({
    Duration fast = const Duration(milliseconds: 5),
    Duration slow = const Duration(milliseconds: 20),
  }) => PanePoller(api, 'w1:p1', fast: fast, slow: slow);

  int reads() => herdr.count('pane.read');

  setUp(() {
    herdr = FakeHerdr();
    client = herdr.client;
    poller = build();
  });
  tearDown(() => poller.dispose());

  group('PanePoller', () {
    test('reads with colours, and only so much history', () async {
      poller.start();
      await until(() => poller.view.value.text == 'hello', 'the text');
      final read = herdr.reads.first;
      expect(read['pane_id'], 'w1:p1');
      expect(read['source'], 'recent_unwrapped');
      expect(read['format'], 'ansi');
      expect(read['strip_ansi'], false);
      expect(read['lines'], PanePoller.historyLines);
    });

    test('the same text is not published again', () async {
      var published = 0;
      poller.view.addListener(() => published++);
      poller.start();
      await until(() => reads() >= 4, 'more reads');
      expect(published, 1);
    });

    test('new text is published', () async {
      poller.start();
      await until(() => poller.view.value.text == 'hello', 'the text');
      herdr.paneText = 'world';
      await until(() => poller.view.value.text == 'world', 'the new text');
    });

    test('it slows down while nothing changes', () async {
      poller.dispose();
      poller = build(
        fast: const Duration(milliseconds: 10),
        slow: const Duration(seconds: 5),
      );
      poller.start();
      await until(() => reads() >= 3, 'three reads');
      // 10, 20, 40, 80 ms: a fixed rate would read 30 times in 300 ms.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(reads(), lessThan(9));
    });

    test('kick reads at once, also from a long wait', () async {
      poller.dispose();
      poller = build(
        fast: const Duration(minutes: 1),
        slow: const Duration(minutes: 1),
      );
      poller.start();
      await until(() => reads() == 1, 'the first read');
      await Future<void>.delayed(_settle);
      expect(reads(), 1);
      poller.kick();
      await until(() => reads() == 2, 'the read after the kick');
    });

    test('a kick during a read brings another read', () async {
      poller.dispose();
      poller = build(
        fast: const Duration(minutes: 1),
        slow: const Duration(minutes: 1),
      );
      herdr.holdReads = Completer();
      poller.start();
      await until(() => reads() == 1, 'the first read');
      poller.kick();
      await Future<void>.delayed(_settle);
      expect(reads(), 1, reason: 'one read at a time');
      herdr.holdReads!.complete();
      herdr.holdReads = null;
      await until(() => reads() == 2, 'the read after the kick');
    });

    test('the exact screen reads the visible source, whole', () async {
      poller.start();
      await until(() => reads() >= 1, 'a read');
      herdr.paneTexts['visible'] = 'screen';
      poller.source = ReadSource.visible;
      await until(() => poller.view.value.text == 'screen', 'the screen');
      expect(herdr.reads.last['source'], 'visible');
      expect(herdr.reads.last.containsKey('lines'), isFalse);
    });

    test('a read from before a switch of source is dropped', () async {
      herdr.paneTexts['visible'] = 'screen';
      herdr.holdReads = Completer();
      poller.start();
      await until(() => reads() == 1, 'the first read');
      poller.source = ReadSource.visible;
      herdr.holdReads!.complete();
      herdr.holdReads = null;
      final seen = <String?>[];
      poller.view.addListener(() => seen.add(poller.view.value.text));
      await until(() => seen.contains('screen'), 'the screen');
      expect(seen, isNot(contains('hello')));
    });

    test('a closed pane ends the polling and keeps the text', () async {
      poller.start();
      await until(() => poller.view.value.text == 'hello', 'the text');
      herdr.errors['pane.read'] = ['pane_not_found'];
      await until(() => poller.view.value.gone, 'the end');
      expect(poller.view.value.text, 'hello');
      expect(poller.view.value.error, isNull);
      final after = reads();
      await Future<void>.delayed(_settle);
      expect(reads(), after);
    });

    test('a failed read is reported, and the next one clears it', () async {
      poller.start();
      await until(() => poller.view.value.text == 'hello', 'the text');
      herdr.errors['pane.read'] = ['internal'];
      await until(() => poller.view.value.error != null, 'the error');
      expect(poller.view.value.text, 'hello');
      expect(poller.view.value.gone, isFalse);
      await until(() => poller.view.value.error == null, 'the next read');
      expect(poller.view.value.text, 'hello');
    });

    test('a channel that fails does not end the polling', () async {
      poller.start();
      await until(() => poller.view.value.text == 'hello', 'the text');
      herdr.broken.add('pane.read');
      await until(() => poller.view.value.error != null, 'the error');
      herdr.broken.clear();
      herdr.paneText = 'after';
      await until(() => poller.view.value.text == 'after', 'the next read');
      expect(poller.view.value.error, isNull);
    });

    test('it waits for a link, and uses the new one', () async {
      client = null;
      poller.start();
      await Future<void>.delayed(_settle);
      expect(reads(), 0);
      expect(poller.view.value.error, isNull);
      client = herdr.client;
      await until(() => poller.view.value.text == 'hello', 'the text');
    });

    test('pause stops the reads, resume reads at once', () async {
      poller.dispose();
      poller = build();
      poller.start();
      await until(() => reads() >= 1, 'a read');
      poller.pause();
      await Future<void>.delayed(_settle);
      final paused = reads();
      await Future<void>.delayed(_settle);
      expect(reads(), paused);
      poller.resume();
      await until(() => reads() > paused, 'a read after resume');
    });

    test('a kick while paused does not read', () async {
      poller.start();
      await until(() => reads() >= 1, 'a read');
      poller.pause();
      await Future<void>.delayed(_settle);
      final paused = reads();
      poller.kick();
      await Future<void>.delayed(_settle);
      expect(reads(), paused);
    });

    test('a read that arrives after dispose is dropped', () async {
      final other = build();
      herdr.holdReads = Completer();
      other.start();
      await until(() => reads() == 1, 'the read');
      other.dispose();
      herdr.holdReads!.complete();
      await Future<void>.delayed(_settle);
      expect(reads(), 1);
    });
  });

  group('PaneSender', () {
    late int sent;
    late PaneSender sender;

    setUp(() {
      sent = 0;
      sender = PaneSender(api, 'w1:p1', onSent: () => sent++);
    });

    List<String?> methods() => [for (final (m, _) in herdr.inputs) m];

    test('a key goes through pane.send_keys', () async {
      await sender.keys(['ctrl+c']);
      expect(herdr.inputs.single.$1, 'pane.send_keys');
      expect(herdr.inputs.single.$2, {
        'pane_id': 'w1:p1',
        'keys': ['ctrl+c'],
      });
      expect(sent, 1);
    });

    test('a prompt to an agent goes through agent.prompt', () async {
      await sender.prompt('fix it', toAgent: true);
      expect(herdr.inputs.single.$1, 'agent.prompt');
      expect(herdr.inputs.single.$2, {'target': 'w1:p1', 'text': 'fix it'});
    });

    test('a shell gets the text and Enter', () async {
      await sender.prompt('ls', toAgent: false);
      expect(herdr.inputs.single.$1, 'pane.send_input');
      expect(herdr.inputs.single.$2, {
        'pane_id': 'w1:p1',
        'text': 'ls',
        'keys': ['enter'],
      });
    });

    test('input goes one at a time, in order', () async {
      herdr.holdInput = Completer();
      final first = sender.keys(['esc']);
      final second = sender.keys(['1']);
      await until(() => herdr.inputs.isNotEmpty, 'the first key');
      await Future<void>.delayed(_settle);
      expect(herdr.inputs, hasLength(1), reason: 'the second one waits');
      herdr.holdInput!.complete();
      herdr.holdInput = null;
      await first;
      await second;
      expect([for (final (_, p) in herdr.inputs) p['keys']], [
        ['esc'],
        ['1'],
      ]);
    });

    test('a failure drops what is queued behind it', () async {
      herdr.errors['pane.send_keys'] = ['internal'];
      final first = sender.keys(['esc']);
      final second = sender.keys(['1']);
      await expectLater(first, throwsA(isA<HerdrApiException>()));
      await expectLater(
        second,
        throwsA(
          isA<PaneInputNotSent>().having((e) => e.noLink, 'noLink', false),
        ),
      );
      expect(herdr.count('pane.send_keys'), 1);
      expect(sent, 0);
    });

    test('input after a failure goes out again', () async {
      herdr.errors['pane.send_keys'] = ['internal'];
      await expectLater(sender.keys(['esc']), throwsA(isA<HerdrException>()));
      await sender.keys(['1']);
      expect(methods(), ['pane.send_keys']);
      expect(sent, 1);
    });

    test('cancel drops what is queued, and only that', () async {
      herdr.holdInput = Completer();
      final first = sender.keys(['esc']);
      final second = sender.keys(['enter']);
      await until(() => herdr.inputs.isNotEmpty, 'the first key');
      sender.cancel();
      herdr.holdInput!.complete();
      herdr.holdInput = null;
      await first;
      await expectLater(second, throwsA(isA<PaneInputNotSent>()));
      expect(herdr.inputs, hasLength(1));
    });

    test('a channel that fails counts as a failure', () async {
      herdr.broken.add('pane.send_keys');
      await expectLater(
        sender.keys(['esc']),
        throwsA(isA<HerdrConnectionClosedException>()),
      );
    });

    test('without a link nothing goes out', () async {
      client = null;
      await expectLater(
        sender.keys(['esc']),
        throwsA(isA<PaneInputNotSent>().having((e) => e.noLink, 'noLink', true)),
      );
      expect(herdr.inputs, isEmpty);
    });
  });
}
