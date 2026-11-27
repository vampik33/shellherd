import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/ui/ansi_text.dart';
import 'package:shellherd/ui/palette.dart';

void main() {
  List<String> plain(String text) =>
      parseAnsi(text).map((l) => l.toPlainText()).toList();

  /// The style of the first piece of the only line.
  TextStyle styleOf(String text) =>
      (parseAnsi(text).single.children!.first as TextSpan).style!;

  group('parseAnsi', () {
    test('splits CRLF lines and keeps empty ones', () {
      expect(plain('a\r\n\r\nb'), ['a', '', 'b']);
    });

    test('a line break at the end gives an empty last line', () {
      expect(plain('a\r\n'), ['a', '']);
    });

    test('plain text has the default colour', () {
      expect(styleOf('a').color, Graphite.terminalForeground);
      expect(styleOf('a').backgroundColor, isNull);
    });

    test('the sequences are gone from the text', () {
      expect(plain('\x1b[0m\x1b[38;5;1mred\x1b[0m x'), ['red x']);
    });

    test('other sequences are dropped, not shown', () {
      expect(plain('a\x1b[2Kb\x1b[?25lc\x1bd'), ['abcd']);
    });

    test('basic colours', () {
      expect(styleOf('\x1b[31mx').color, Graphite.red);
      expect(styleOf('\x1b[42mx').backgroundColor, Graphite.green);
      expect(styleOf('\x1b[91mx').color, graphiteTerminalTheme.brightRed);
    });

    test('256 colours: palette, cube and grey', () {
      expect(styleOf('\x1b[38;5;1mx').color, Graphite.red);
      expect(styleOf('\x1b[38;5;208mx').color, const Color(0xFFFF8700));
      expect(styleOf('\x1b[48;5;232mx').backgroundColor, const Color(0xFF080808));
    });

    test('RGB colours', () {
      expect(styleOf('\x1b[38;2;1;2;3mx').color, const Color(0xFF010203));
      expect(styleOf('\x1b[48;2;4;5;6mx').backgroundColor, const Color(0xFF040506));
    });

    test('several codes in one sequence', () {
      final s = styleOf('\x1b[1;4;38;5;2;3mx');
      expect(s.fontWeight, FontWeight.w700);
      expect(s.decoration, TextDecoration.underline);
      expect(s.color, Graphite.green);
      expect(s.fontStyle, FontStyle.italic);
    });

    test('a cut-off colour changes nothing and does not throw', () {
      expect(styleOf('\x1b[38;5mx').color, Graphite.terminalForeground);
      expect(styleOf('\x1b[38;2;1mx').color, Graphite.terminalForeground);
      expect(styleOf('\x1b[38mx').color, Graphite.terminalForeground);
      expect(styleOf('\x1b[38;5;999mx').color, Graphite.terminalForeground);
    });

    test('reset codes end what they should', () {
      expect(styleOf('\x1b[31;39mx').color, Graphite.terminalForeground);
      expect(styleOf('\x1b[41;49mx').backgroundColor, isNull);
      expect(styleOf('\x1b[1;22mx').fontWeight, FontWeight.w400);
      expect(styleOf('\x1b[31m\x1b[mx').color, Graphite.terminalForeground);
    });

    test('inverse swaps the colours', () {
      final s = styleOf('\x1b[7mx');
      expect(s.color, Graphite.background);
      expect(s.backgroundColor, Graphite.terminalForeground);
      final red = styleOf('\x1b[31;7mx');
      expect(red.backgroundColor, Graphite.red);
    });

    test('a style goes on over the end of a line', () {
      final lines = parseAnsi('\x1b[31ma\r\nb');
      expect(
        (lines[1].children!.single as TextSpan).style!.color,
        Graphite.red,
      );
    });
  });

  test('ansiCarries tells whether a colour or style is left on', () {
    for (final (text, carries) in [
      ('', false),
      ('plain\ntext', false),
      ('\x1b[31mred', true),
      ('\x1b[31mred\x1b[0m', false),
      ('\x1b[31mred\x1b[39m', false),
      ('\x1b[1mbold\x1b[22m', false),
      ('\x1b[38;5;9mcolour\nnext line', true),
      ('\x1b[7minverse', true),
      ('\x1b[44mback\x1b[49m and \x1b[4munder', true),
      ('\x1b[2Jcleared', false),
    ]) {
      expect(ansiCarries(text), carries, reason: text);
    }
  });
}
