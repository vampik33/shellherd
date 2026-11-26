import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/transcript/transcript_stream.dart';

void main() {
  group('readEarlier', () {
    test('reads back every line short enough to keep, in order', () async {
      for (var seed = 0; seed < 2000; seed++) {
        final r = Random(seed);
        const maxLine = 12;
        final lines = [
          for (var i = r.nextInt(30); i > 0; i--)
            String.fromCharCodes([
              for (var j = r.nextInt(r.nextInt(4) == 0 ? 40 : 10); j > 0; j--)
                97 + r.nextInt(3),
            ]),
        ];
        final file = utf8.encode(lines.map((l) => '$l\n').join());
        // The read starts at a random line: what the first read kept.
        final held = r.nextInt(lines.length + 1);
        var start = utf8
            .encode(lines.take(held).map((l) => '$l\n').join())
            .length;
        final chunk = 1 + r.nextInt(20);
        var inLine = false;
        final got = <String>[];
        var reads = 0;
        while (start > 0) {
          final before = start;
          // Each read of one load goes on before the last: no byte twice.
          var next = start;
          var bytes = 0;
          final found = await readEarlier(
            (from, to) async {
              reads++;
              expect(from, greaterThanOrEqualTo(0));
              expect(to, next, reason: 'seed $seed');
              next = from;
              bytes += to - from;
              return file.sublist(from, to);
            },
            start: start,
            inLine: inLine,
            chunk: chunk,
            maxLine: maxLine,
          );
          expect(found.start, lessThan(before), reason: 'seed $seed: progress');
          expect(bytes, lessThanOrEqualTo(max(chunk, maxLine + 1) + 1));
          got.insertAll(0, found.lines.map(utf8.decode));
          start = found.start;
          inLine = found.inLine;
          expect(reads, lessThan(10000), reason: 'seed $seed');
        }
        expect(got, [
          for (final l in lines.take(held))
            if (l.length <= maxLine) l,
        ], reason: 'seed $seed, chunk $chunk');
      }
    });

    test('a read that comes back short fails', () async {
      await expectLater(
        readEarlier((from, to) async => [0x0a], start: 10, inLine: false),
        throwsStateError,
      );
    });
  });

  group('earlierLines', () {
    test('drops the cut first line and starts after it', () {
      final found = earlierLines(
        utf8.encode('ut\none\ntwo\n'),
        readFrom: 5,
        inLine: false,
      )!;
      expect(found.lines.map(utf8.decode), ['one', 'two']);
      expect(found.start, 8);
      expect(found.inLine, isFalse);
    });

    test('keeps the first line at the start of the file', () {
      final found = earlierLines(
        utf8.encode('zero\none\n'),
        readFrom: 0,
        inLine: false,
      )!;
      expect(found.lines.map(utf8.decode), ['zero', 'one']);
      expect(found.start, 0);
    });

    test('a line start right after the byte before', () {
      // The byte before the range is the newline of the line before it.
      final found = earlierLines(
        utf8.encode('\none\n'),
        readFrom: 3,
        inLine: false,
      )!;
      expect(found.lines.map(utf8.decode), ['one']);
      expect(found.start, 4);
    });

    test('one line that may be kept asks for more', () {
      expect(
        earlierLines(
          utf8.encode('abc\n'),
          readFrom: 9,
          inLine: false,
          maxLine: 5,
        ),
        isNull,
      );
    });

    test('one line too long to keep is dropped from where it was read', () {
      final found = earlierLines(
        utf8.encode('abcdefg\n'),
        readFrom: 9,
        inLine: false,
        maxLine: 5,
      )!;
      expect(found.lines, isEmpty);
      expect(found.start, 10);
      expect(found.inLine, isTrue);
    });

    test('inside a dropped line, the lines before its start', () {
      final found = earlierLines(
        utf8.encode('ut\none\nlong-line-he'),
        readFrom: 4,
        inLine: true,
        maxLine: 5,
      )!;
      expect(found.lines.map(utf8.decode), ['one']);
      expect(found.start, 7);
      expect(found.inLine, isFalse);
    });

    test('bytes that do not end a line are refused', () {
      expect(
        () => earlierLines(utf8.encode('abc'), readFrom: 1, inLine: false),
        throwsArgumentError,
      );
      expect(
        () => earlierLines(const [], readFrom: 1, inLine: true),
        throwsArgumentError,
      );
    });
  });
}
