/// TranscriptStream with a fake opener, on the real clock.
@Timeout(Duration(seconds: 30))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/transcript/chat_items.dart';
import 'package:shellherd/herdr/transcript/claude_transcript.dart';
import 'package:shellherd/herdr/transcript/transcript_stream.dart';

import '../support/fake_transcripts.dart';
import '../support/poll.dart';

/// Long enough for a step that should not happen to show.
const _settle = Duration(milliseconds: 30);

void main() {
  late FakeTranscripts transcripts;
  late ValueNotifier<int> changes;
  TranscriptOpener? opener;
  String? session;
  late TranscriptStream stream;

  setUp(() {
    transcripts = FakeTranscripts();
    changes = ValueNotifier(0);
    opener = transcripts.open;
    session = 's1';
    stream = TranscriptStream(
      () => opener,
      () => session,
      changes: changes,
      openTimeout: const Duration(milliseconds: 300),
      retryDelay: const Duration(milliseconds: 10),
    );
  });
  tearDown(() => stream.dispose());

  List<ChatItem>? items() => stream.view.value.items;
  void change() => changes.value++;

  test(
    'reads nothing until it runs, then the transcript of the pane',
    () async {
      await Future<void>.delayed(_settle);
      expect(transcripts.opened, isEmpty);
      stream.running = true;
      await until(
        () => transcripts.opened.isNotEmpty,
        'transcripts.opened.isNotEmpty',
      );
      expect(transcripts.last.session, session);
      transcripts.last.file([
        claudeUser('hi'),
        claudeAssistant([claudeText('hello')]),
      ]);
      await until(() => items()?.length == 2, 'items()?.length == 2');
      expect(items(), const [ChatPrompt('hi'), ChatReply('hello')]);
      expect(stream.view.value.startsCut, isFalse);
    },
  );

  test('lines before the header are the shell talking', () async {
    stream.running = true;
    await until(
      () => transcripts.opened.isNotEmpty,
      'transcripts.opened.isNotEmpty',
    );
    transcripts.last
      ..text('Welcome!\n${claudeUser('not read')}\n')
      ..file([claudeUser('read')]);
    await until(() => items() != null, 'items() != null');
    expect(items(), const [ChatPrompt('read')]);
  });

  test(
    'shows nothing until the end of the file came, then each record',
    () async {
      stream.running = true;
      await until(
        () => transcripts.opened.isNotEmpty,
        'transcripts.opened.isNotEmpty',
      );
      final first = '${claudeUser('one')}\n';
      final second = '${claudeUser('two')}\n';
      final channel = transcripts.last
        ..header(utf8.encode(first + second).length)
        ..text(first);
      await Future<void>.delayed(_settle);
      expect(items(), isNull, reason: 'half of the start is not shown');
      channel.text(second);
      await until(() => items()?.length == 2, 'items()?.length == 2');
      channel.text('${claudeUser('three')}\n');
      await until(() => items()?.length == 3, 'items()?.length == 3');
    },
  );

  test('a last record without its newline does not hold back the ones '
      'before it, and shows once its newline comes', () async {
    stream.running = true;
    await until(
      () => transcripts.opened.isNotEmpty,
      'transcripts.opened.isNotEmpty',
    );
    final whole = '${claudeUser('one')}\n';
    final partial = claudeUser('two');
    transcripts.last
      ..header(utf8.encode(whole + partial).length)
      ..text(whole)
      ..text(partial);
    await until(() => items() != null, 'items() != null');
    expect(items(), const [ChatPrompt('one')]);
    transcripts.last.text('\n');
    await until(() => items()?.length == 2, 'items()?.length == 2');
    expect(items(), const [ChatPrompt('one'), ChatPrompt('two')]);
  });

  test('a line over the cap is dropped and the chat still loads', () async {
    stream.running = true;
    await until(
      () => transcripts.opened.isNotEmpty,
      'transcripts.opened.isNotEmpty',
    );
    final huge = '${'x' * maxTranscriptLine}x\n';
    // Longer than the tail: the read starts cut, and the records after
    // the dropped line show once all of its bytes came.
    final body = 'cut"}}\n$huge${claudeUser('one')}\n';
    transcripts.last
      ..header(utf8.encode(body).length)
      ..text(body);
    await until(() => items() != null, 'items() != null');
    expect(items(), const [ChatPrompt('one')]);
    expect(stream.view.value.startsCut, isTrue);
    transcripts.last.text('$huge${claudeUser('two')}\n');
    await until(() => items()?.length == 2, 'items()?.length == 2');
  });

  test('a cut start drops its first line and says so', () async {
    stream.running = true;
    await until(
      () => transcripts.opened.isNotEmpty,
      'transcripts.opened.isNotEmpty',
    );
    final rest = '${claudeUser('whole')}\n';
    final cut = 'er", "content": "cut"}}\n';
    // A file bigger than the tail: the read starts with its last part.
    // The read starts one byte before the tail.
    final tail =
        '${'x' * (transcriptTail + 1 - cut.length - rest.length - 1)}\n';
    expect(utf8.encode(cut + tail + rest).length, transcriptTail + 1);
    transcripts.last
      ..header(transcriptTail * 3)
      ..text(cut)
      ..text(tail)
      ..text(rest);
    // The first line, cut, is dropped whatever it holds; the filler line
    // is no record.
    await until(() => items() != null, 'items() != null');
    expect(items(), const [ChatPrompt('whole')]);
    expect(stream.view.value.startsCut, isTrue);
  });

  test('a cut that falls where a record starts keeps that record', () async {
    stream.running = true;
    await until(
      () => transcripts.opened.isNotEmpty,
      'transcripts.opened.isNotEmpty',
    );
    final first = '${claudeUser('first')}\n';
    final rest = '${claudeUser('whole')}\n';
    final filler =
        '${'x' * (transcriptTail - first.length - rest.length - 1)}\n';
    // The byte before the tail is the newline of the record before it.
    final read = '\n$first$filler$rest';
    expect(utf8.encode(read).length, transcriptTail + 1);
    transcripts.last
      ..header(transcriptTail * 3)
      ..text(read);
    await until(() => items() != null, 'items() != null');
    expect(items(), const [ChatPrompt('first'), ChatPrompt('whole')]);
    expect(stream.view.value.startsCut, isTrue);
  });

  test('a file one byte longer than the tail is read whole', () async {
    stream.running = true;
    await until(
      () => transcripts.opened.isNotEmpty,
      'transcripts.opened.isNotEmpty',
    );
    final first = '${claudeUser('first')}\n';
    final body = '$first${'x' * (transcriptTail - first.length)}\n';
    expect(utf8.encode(body).length, transcriptTail + 1);
    transcripts.last
      ..header(transcriptTail + 1)
      ..text(body);
    await until(() => items() != null, 'items() != null');
    expect(items(), const [ChatPrompt('first')]);
    expect(stream.view.value.startsCut, isFalse);
  });

  test('startup text without a newline before the header', () async {
    stream.running = true;
    await until(
      () => transcripts.opened.isNotEmpty,
      'transcripts.opened.isNotEmpty',
    );
    transcripts.last
      ..text('Welcome!')
      ..file([claudeUser('read')]);
    await until(() => items() != null, 'items() != null');
    expect(items(), const [ChatPrompt('read')]);
  });

  test('retryWait doubles from the second failure, up to the most', () {
    const first = Duration(seconds: 1);
    const most = Duration(seconds: 30);
    expect(
      [for (var f = 0; f <= 7; f++) retryWait(f, first, most).inSeconds],
      [1, 1, 2, 4, 8, 16, 30, 30],
    );
    expect(retryWait(1000, first, most), most);
  });

  test('reads that end with nothing new start again ever later; one that '
      'brings a record makes the next wait short again', () async {
    stream.dispose();
    stream = TranscriptStream(
      () => opener,
      () => session,
      changes: changes,
      retryDelay: const Duration(milliseconds: 100),
      maxRetryDelay: const Duration(seconds: 10),
    )..running = true;
    Future<void> opened(int n) => until(
      () => transcripts.opened.length == n,
      '$n reads',
      within: const Duration(seconds: 10),
    );
    await opened(1);
    // Five reads that end at once, with an empty file.
    for (var n = 1; n <= 5; n++) {
      transcripts.last
        ..header(0)
        ..close();
      await opened(n + 1);
    }
    // One that brings a record.
    transcripts.last
      ..header(0)
      ..text('${claudeUser('new')}\n')
      ..close();
    await opened(7);
    final at = transcripts.openedAt;
    final gaps = [
      for (var i = 1; i < at.length; i++)
        at[i].difference(at[i - 1]).inMilliseconds,
    ];
    const waits = [100, 200, 400, 800, 1600];
    for (var i = 0; i < waits.length; i++) {
      expect(gaps[i], greaterThanOrEqualTo(waits[i]), reason: 'gaps $gaps');
    }
    expect(gaps.last, lessThan(1600), reason: 'gaps $gaps');
  });

  test('a new link after a failed read opens one read', () async {
    // As the pane screen does: no read runs while the read is unavailable,
    // so clearing it starts one at once.
    stream.unavailable.addListener(
      () => stream.running = !stream.unavailable.value,
    );
    stream.running = true;
    await until(
      () => transcripts.opened.isNotEmpty,
      'transcripts.opened.isNotEmpty',
    );
    transcripts.last.fail(StateError('exit 66: cannot read'));
    await until(() => stream.unavailable.value, 'stream.unavailable.value');
    final next = FakeTranscripts();
    opener = next.open;
    change();
    await until(() => next.opened.isNotEmpty, 'the new read');
    await Future<void>.delayed(_settle);
    expect(next.opened, hasLength(1));
  });

  test(
    'a read that fails before its header falls back, until a new link',
    () async {
      stream.running = true;
      await until(
        () => transcripts.opened.isNotEmpty,
        'transcripts.opened.isNotEmpty',
      );
      transcripts.last.fail(
        const HerdrConnectException('transcript read', 'exit 66: cannot read'),
      );
      await until(() => stream.unavailable.value, 'stream.unavailable.value');
      expect(stream.whyUnavailable, contains('cannot read'));
      expect(stream.canRead, isFalse);
      change();
      await Future<void>.delayed(_settle);
      expect(transcripts.opened, hasLength(1), reason: 'no retry on the link');
      opener = FakeTranscripts().open;
      change();
      expect(stream.unavailable.value, isFalse);
    },
  );

  test('a read without a header in time falls back', () async {
    stream.running = true;
    await until(
      () => transcripts.opened.isNotEmpty,
      'transcripts.opened.isNotEmpty',
    );
    await until(() => stream.unavailable.value, 'stream.unavailable.value');
    expect(transcripts.last.closed, isTrue);
  });

  test('an open that fails falls back with the reason', () async {
    transcripts.failOpen = StateError('channel refused');
    stream.running = true;
    await until(() => stream.unavailable.value, 'stream.unavailable.value');
    expect(stream.whyUnavailable, contains('channel refused'));
  });

  test('a read that ends after its header starts again and keeps the chat '
      'until the new one is in', () async {
    stream.running = true;
    await until(
      () => transcripts.opened.isNotEmpty,
      'transcripts.opened.isNotEmpty',
    );
    transcripts.last.file([claudeUser('one')]);
    await until(() => items()?.length == 1, 'items()?.length == 1');
    final shown = <List<ChatItem>?>[];
    stream.view.addListener(() => shown.add(items()));
    transcripts.last.close();
    await until(
      () => transcripts.opened.length == 2,
      'transcripts.opened.length == 2',
    );
    final body = '${claudeUser('one')}\n${claudeUser('two')}\n';
    transcripts.last
      ..header(utf8.encode(body).length)
      ..text(body.substring(0, 10));
    await Future<void>.delayed(_settle);
    expect(items(), const [ChatPrompt('one')]);
    transcripts.last.text(body.substring(10));
    await until(() => items()?.length == 2, 'items()?.length == 2');
    expect(shown.every((s) => s != null && s.isNotEmpty), isTrue);
    expect(stream.unavailable.value, isFalse);
  });

  test('a new session clears the chat and reads its transcript', () async {
    stream.running = true;
    await until(
      () => transcripts.opened.isNotEmpty,
      'transcripts.opened.isNotEmpty',
    );
    transcripts.last.file([claudeUser('old')]);
    await until(() => items() != null, 'items() != null');
    final old = transcripts.last;
    session = 's2';
    change();
    expect(items(), isNull);
    expect(old.closed, isTrue);
    await until(
      () => transcripts.opened.length == 2,
      'transcripts.opened.length == 2',
    );
    expect(transcripts.last.session, session);
  });

  test('a pane without a transcript reads nothing', () async {
    session = null;
    change();
    stream.running = true;
    await Future<void>.delayed(_settle);
    expect(transcripts.opened, isEmpty);
    expect(stream.canRead, isFalse);
  });

  test('stopping closes the read; a late open is closed', () async {
    stream.running = true;
    await until(
      () => transcripts.opened.isNotEmpty,
      'transcripts.opened.isNotEmpty',
    );
    stream.running = false;
    expect(transcripts.last.closed, isTrue);
    transcripts.holdOpen = Completer();
    stream.running = true;
    await Future<void>.delayed(_settle);
    stream.dispose();
    transcripts.holdOpen!.complete();
    await until(
      () => transcripts.opened.length == 2,
      'transcripts.opened.length == 2',
    );
    await until(() => transcripts.last.closed, 'transcripts.last.closed');
    // tearDown disposes again: build a fresh stream for it.
    stream = TranscriptStream(() => null, () => null, changes: changes);
  });

  group('a new read goes on where the last stopped', () {
    String line(String text) => '${claudeUser(text)}\n';
    int length(String s) => utf8.encode(s).length;

    Future<void> opened(int n) =>
        until(() => transcripts.opened.length == n, '$n reads');

    test('after a new link, without what the last read had', () async {
      stream.running = true;
      await opened(1);
      final first = line('one') + line('two');
      transcripts.last
        ..header(length(first), inode: '7')
        ..text(first)
        // Half a record: the next read has to send it again.
        ..text(line('three').substring(0, 5));
      await until(() => items()?.length == 2, 'two items');
      expect(transcripts.last.from, isNull);
      final next = FakeTranscripts();
      opener = next.open;
      change();
      await until(() => next.opened.isNotEmpty, 'the new read');
      expect(next.last.from, (inode: '7', offset: length(first)));
      final rest = line('three') + line('four');
      next.last
        ..header(length(first + rest), start: length(first), inode: '7')
        ..text(rest);
      await until(() => items()?.length == 4, 'four items');
      expect(items(), const [
        ChatPrompt('one'),
        ChatPrompt('two'),
        ChatPrompt('three'),
        ChatPrompt('four'),
      ]);
      expect(stream.view.value.startsCut, isFalse);
    });

    test('after the chat was hidden', () async {
      stream.running = true;
      await opened(1);
      transcripts.last.file([claudeUser('one')]);
      await until(() => items()?.length == 1, 'one item');
      stream.running = false;
      stream.running = true;
      await opened(2);
      expect(transcripts.last.from, (inode: '1', offset: length(line('one'))));
    });

    test('a read the command starts elsewhere starts over', () async {
      stream.running = true;
      await opened(1);
      transcripts.last.file([claudeUser('one')]);
      await until(() => items()?.length == 1, 'one item');
      transcripts.last.close();
      await opened(2);
      expect(transcripts.last.from, isNotNull);
      // Another file, or the mark was too far behind: the whole file.
      transcripts.last.file([claudeUser('one'), claudeUser('two')]);
      await until(() => items()?.length == 2, 'two items');
      expect(items(), const [ChatPrompt('one'), ChatPrompt('two')]);
    });

    test('a cut read has a mark only once its first line ended', () async {
      stream.running = true;
      await opened(1);
      const start = 1000;
      transcripts.last
        ..header(start + 50, start: start, inode: '7')
        ..text('end of a cut record');
      await Future<void>.delayed(_settle);
      transcripts.last.close();
      await opened(2);
      expect(transcripts.last.from, isNull);
      final cut = 'end of a cut record\n';
      transcripts.last
        ..header(start + 50, start: start, inode: '7')
        ..text(cut)
        ..close();
      await opened(3);
      expect(transcripts.last.from, (inode: '7', offset: start + length(cut)));
    });

    test('a read that waited for the file has no mark', () async {
      stream.running = true;
      await opened(1);
      transcripts.last
        ..header(0, inode: '-')
        ..text(line('one'));
      await until(() => items()?.length == 1, 'one item');
      transcripts.last.close();
      await opened(2);
      expect(transcripts.last.from, isNull);
    });

    test('a new session starts from its end', () async {
      stream.running = true;
      await opened(1);
      transcripts.last.file([claudeUser('one')]);
      await until(() => items()?.length == 1, 'one item');
      session = 's2';
      change();
      await opened(2);
      expect(transcripts.last.from, isNull);
    });

    test('reads that drop anywhere end with the chat of one read', () async {
      for (var seed = 0; seed < 40; seed++) {
        final random = Random(seed);
        // The command's tail, small so that reads are cut and marks fall
        // too far behind.
        final tail = 60 + random.nextInt(500);
        final file = <int>[];
        var records = 0;
        void grow() {
          for (var n = random.nextInt(4); n > 0; n--) {
            // No uuid: a record read twice shows twice.
            file.addAll(
              utf8.encode(line('m${records++} ü€ ${'x' * random.nextInt(90)}')),
            );
          }
        }

        grow();
        final drops = random.nextInt(5);
        var reads = 0;
        // Where the last read that did not go on started.
        var fresh = 0;
        Future<TranscriptChannel> open(
          String session,
          TranscriptMark? from,
        ) async {
          grow();
          final size = file.length;
          var start = size > tail + 1 ? size - tail - 1 : 0;
          if (from != null &&
              from.inode == '7' &&
              size >= from.offset &&
              size - from.offset <= tail) {
            start = from.offset;
          } else {
            fresh = start;
          }
          final channel = FakeTranscriptChannel(session, from);
          final header = utf8.encode('$transcriptHeader$size $start 7\n');
          final bytes = [...header, ...file.sublist(start)];
          final last = ++reads > drops;
          // A read that drops before its header would fall back.
          final end = last
              ? bytes.length
              : header.length +
                    random.nextInt(bytes.length - header.length + 1);
          for (var at = 0; at < end;) {
            final next = min(end, at + 1 + random.nextInt(80));
            channel.bytes(bytes.sublist(at, next));
            at = next;
          }
          if (!last) channel.close();
          return channel;
        }

        final reader = TranscriptStream(
          () => open,
          () => 's',
          changes: changes,
          retryDelay: const Duration(milliseconds: 1),
          maxRetryDelay: const Duration(milliseconds: 4),
        )..running = true;
        await until(() => reads > drops, 'seed $seed: the last read');
        final want = ClaudeTranscript();
        final lines = utf8.decode(file.sublist(fresh)).split('\n');
        lines.skip(fresh > 0 ? 1 : 0).forEach(want.add);
        await until(
          () => listEquals(reader.view.value.items, want.items),
          'seed $seed: the chat of one read from $fresh, '
          'got ${reader.view.value.items}, want ${want.items}',
        );
        reader.dispose();
      }
    });
  });
}
