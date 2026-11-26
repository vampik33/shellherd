import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/pane_history.dart';

void main() {
  group('olderLines', () {
    /// The pane's history, as reads of its last [n] lines give it.
    List<String> last(List<String> lines, int n) =>
        lines.sublist(max(0, lines.length - n));

    test('finds the older read in a deeper one, after new output and a '
        'changed screen', () {
      for (var seed = 0; seed < 4000; seed++) {
        final r = Random(seed);
        // Unique lines: the place is known.
        final history = [
          for (var i = 0; i < 50 + r.nextInt(400); i++) 'line $i',
        ];
        // Half of them start with a run of blank or repeated lines, which
        // new output shifts against itself.
        final repeated = seed.isOdd;
        final shownCount = repeated
            ? min(history.length, 50 + r.nextInt(200))
            : 1 + r.nextInt(min(120, history.length));
        final firstShown = history.length - shownCount;
        final runCount = repeated ? min(shownCount, 50 + r.nextInt(100)) : 0;
        final blank = r.nextBool();
        for (var i = firstShown; i < firstShown + runCount; i++) {
          // Alike once escapes and trailing blanks are dropped.
          history[i] = [
            if (blank) ...['', '   ', '\x1b[0m', '\x1b[2m\x1b[0m '],
            if (!blank) ...['beat', 'beat  ', '\x1b[2mbeat\x1b[0m'],
          ][r.nextInt(blank ? 4 : 3)];
        }
        final shown = last(history, shownCount).toList();
        // The screen at the bottom changed since; new lines came.
        for (var i = r.nextInt(5); i > 0 && shown.isNotEmpty; i--) {
          shown[shown.length - 1 - r.nextInt(min(5, shown.length))] =
              'screen ${r.nextInt(99)}';
        }
        final newCount = repeated ? 1 + r.nextInt(60) : r.nextInt(30);
        final grown = [
          ...history,
          for (var i = newCount; i > 0; i--) 'new ${r.nextInt(1000000)}',
        ];
        final deeper = last(
          grown,
          shownCount + (repeated ? newCount : 0) + r.nextInt(300),
        );
        final deeperStart = grown.length - deeper.length;
        final anchor = min(50, shownCount);
        // Its first lines must be unchanged to be found.
        final changed = shown.indexWhere((l) => l.startsWith('screen'));
        final intact = changed < 0 || changed >= anchor;
        final expected = firstShown >= deeperStart && intact
            ? firstShown - deeperStart
            : null;
        final at = olderLines(shown, deeper);
        // Where an unchanged line ends the run, only the place matches
        // that far; otherwise it can be unknown, but never wrong.
        final known = runCount == 0 || changed < 0 || changed > runCount;
        expect(
          at,
          known ? expected : anyOf(isNull, expected),
          reason: 'seed $seed',
        );
      }
    });

    test('a run of repeated lines and new output after it give the place, '
        'not one shifted by the new output', () {
      final history = [
        for (var i = 0; i < 2000; i++) i >= 1600 && i < 1700 ? 'beat' : 'l$i',
      ];
      final shown = history.sublist(1600);
      final grown = [...history, for (var i = 0; i < 50; i++) 'new $i'];
      final deeper = grown.sublist(grown.length - 2000);
      expect(shown, hasLength(400));
      expect(olderLines(shown, deeper), 1550);
    });

    test('with repeated lines, it finds the one place that matches, or '
        'none', () {
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
          // All of it matches there; where it does in another place too,
          // the place is unknown.
          final places = [
            for (var p = 0; p <= deeper.length - shownCount; p++)
              if (listEquals(deeper.sublist(p, p + shownCount), shown)) p,
          ];
          expect(
            at,
            places.length == 1 ? firstShown - deeperStart : isNull,
            reason: 'seed $seed',
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
