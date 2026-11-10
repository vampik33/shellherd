import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/terminal/key_bar.dart';
import 'package:xterm/xterm.dart';

void main() {
  late StickyModifiers mods;
  late StickyTerminal terminal;
  late List<String> sent;

  setUp(() {
    mods = StickyModifiers();
    terminal = StickyTerminal(mods);
    sent = [];
    terminal.onOutput = sent.add;
  });

  group('StickyTerminal', () {
    test('without modifiers, text and keys pass as they are', () {
      terminal.textInput('ls\r');
      terminal.keyInput(TerminalKey.arrowUp);
      expect(sent, ['ls\r', '\x1b[A']);
    });

    test('ctrl changes only the next typed key', () {
      mods.toggleCtrl();
      terminal.textInput('c');
      terminal.textInput('c');
      expect(sent, ['\x03', 'c']);
      expect(mods.ctrl, isFalse);
    });

    test('ctrl maps letters of both cases and the symbols', () {
      for (final (char, code) in [
        ('a', 0x01),
        ('Z', 0x1a),
        ('[', 0x1b),
        (r'\', 0x1c),
        (' ', 0x00),
        ('?', 0x7f),
      ]) {
        mods.toggleCtrl();
        terminal.textInput(char);
        expect(sent.removeLast(), String.fromCharCode(code), reason: char);
      }
    });

    test('ctrl with a character that has no control code sends it as is', () {
      mods.toggleCtrl();
      terminal.textInput('1');
      expect(sent, ['1']);
      expect(mods.ctrl, isFalse, reason: 'the key used the modifier up');
    });

    test('alt puts ESC in front; ctrl and alt together combine', () {
      mods.toggleAlt();
      terminal.textInput('x');
      mods
        ..toggleCtrl()
        ..toggleAlt();
      terminal.textInput('a');
      expect(sent, ['\x1bx', '\x1b\x01']);
    });

    test('a soft-keyboard letter that arrives as keyInput gets ctrl', () {
      // TerminalView sends a typed letter as keyInput first.
      mods.toggleCtrl();
      expect(terminal.keyInput(TerminalKey.keyC), isTrue);
      expect(sent, ['\x03']);
      expect(mods.ctrl, isFalse);
    });

    test('a keyInput that gives no output keeps the modifier on', () {
      expect(terminal.keyInput(TerminalKey.keyC), isFalse);
      mods.toggleAlt();
      // A digit has no alt sequence in keyInput, so TerminalView sends it
      // again as text.
      expect(terminal.keyInput(TerminalKey.digit1), isFalse);
      expect(mods.alt, isTrue);
      terminal.textInput('1');
      expect(sent, ['\x1b1']);
    });

    test('ctrl with an arrow key sends the xterm modifier form', () {
      mods.toggleCtrl();
      terminal.keyInput(TerminalKey.arrowUp);
      expect(sent, ['\x1b[1;5A']);
    });

    test('replies of the terminal to the program ignore the modifiers', () {
      mods.toggleAlt();
      terminal.write('\x1b[c'); // the program asks for device attributes
      expect(sent, hasLength(1));
      expect(sent.single, startsWith('\x1b['));
      expect(mods.alt, isTrue);
    });
  });

  group('KeyBar', () {
    Future<void> pumpBar(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: KeyBar(terminal: terminal)),
      ),
    );

    testWidgets('keys send their sequences', (tester) async {
      await pumpBar(tester);
      for (final label in ['esc', 'tab', '↑', '←', '|', '~']) {
        await tester.tap(find.text(label));
      }
      expect(sent, ['\x1b', '\t', '\x1b[A', '\x1b[D', '|', '~']);
    });

    testWidgets('ctrl stays on for one key and shows that it is on', (
      tester,
    ) async {
      await pumpBar(tester);
      Color colorOf(String label) => tester
          .widget<Material>(
            find
                .ancestor(of: find.text(label), matching: find.byType(Material))
                .first,
          )
          .color!;
      final off = colorOf('ctrl');

      await tester.tap(find.text('ctrl'));
      await tester.pump();
      expect(mods.ctrl, isTrue);
      expect(colorOf('ctrl'), isNot(off));

      await tester.tap(find.text('↓'));
      await tester.pump();
      expect(sent, ['\x1b[1;5B']);
      expect(mods.ctrl, isFalse);
      expect(colorOf('ctrl'), off);

      await tester.tap(find.text('ctrl'));
      await tester.tap(find.text('ctrl'));
      expect(mods.ctrl, isFalse, reason: 'a second tap turns it off');
    });
  });
}
