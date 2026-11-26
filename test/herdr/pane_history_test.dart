import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/pane_history.dart';

void main() {
  group('olderLines', () {
    /// The pane's history, as reads of its last [n] lines give it.
    List<String> last(List<String> lines, int n) =>
        lines.sublist(max(0, lines.length - n));

    test('finds the older read in a deeper one, after new output and a '
        'changed screen', () {
      for (var seed = 0; seed < 2000; seed++) {
        final r = Random(seed);
        // Unique lines: the place is known.
        final history = [
          for (var i = 0; i < 50 + r.nextInt(400); i++) 'line $i',
        ];
        final shownCount = 1 + r.nextInt(min(120, history.length));
        final shown = last(history, shownCount).toList();
        // The screen at the bottom changed since; new lines came.
        for (var i = r.nextInt(5); i > 0 && shown.isNotEmpty; i--) {
          shown[shown.length - 1 - r.nextInt(min(5, shown.length))] =
              'screen ${r.nextInt(99)}';
        }
        final grown = [
          ...history,
          for (var i = r.nextInt(30); i > 0; i--) 'new ${r.nextInt(1000000)}',
        ];
        final deeper = last(grown, shownCount + r.nextInt(300));
        final firstShown = history.length - shownCount;
        final deeperStart = grown.length - deeper.length;
        final anchor = min(50, shownCount);
        // Its first lines must be unchanged to be found.
        final intact = !shown.take(anchor).any((l) => l.startsWith('screen'));
        final expected = firstShown >= deeperStart && intact
            ? firstShown - deeperStart
            : null;
        expect(olderLines(shown, deeper), expected, reason: 'seed $seed');
      }
    });

    test('with repeated lines, what it finds matches, nearest the end', () {
      for (var seed = 0; seed < 2000; seed++) {
        final r = Random(seed);
        final history = [
          for (var i = 0; i < 20 + r.nextInt(200); i++) 'l${r.nextInt(3)}',
        ];
        final shownCount = 1 + r.nextInt(min(80, history.length));
        final shown = last(history, shownCount);
        final grown = [
          ...history,
          for (var i = r.nextInt(10); i > 0; i--) 'l${r.nextInt(3)}',
        ];
        final deeper = last(grown, shownCount + r.nextInt(150));
        final at = olderLines(shown, deeper);
        final firstShown = history.length - shownCount;
        final deeperStart = grown.length - deeper.length;
        final anchor = min(50, shownCount);
        if (at != null) {
          expect(
            deeper.sublist(at, at + anchor),
            shown.sublist(0, anchor),
            reason: 'seed $seed',
          );
          expect(
            at,
            lessThanOrEqualTo(deeper.length - shownCount),
            reason: 'seed $seed: past where no new output puts it',
          );
        }
        if (firstShown >= deeperStart) {
          expect(at, isNotNull, reason: 'seed $seed: it is there');
          expect(
            at,
            greaterThanOrEqualTo(firstShown - deeperStart),
            reason: 'seed $seed: the nearest match',
          );
        }
      }
    });

    test('compares lines without escapes or trailing blanks', () {
      expect(olderLines(['\x1b[1ma\x1b[0m  ', 'b'], ['x', 'a', 'b\r ']), 1);
    });

    test('nothing older, or nothing to find', () {
      expect(olderLines(['a', 'b'], ['a', 'b']), 0);
      expect(olderLines([], ['a']), isNull);
      expect(olderLines(['a', 'b'], ['b']), isNull);
      expect(olderLines(['z'], ['a', 'b']), isNull);
    });
  });
}
