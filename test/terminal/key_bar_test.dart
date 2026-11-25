import 'dart:math';

import 'package:flutter/gestures.dart';
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

    group('paste', () {
      const start = '\x1b[200~', end = '\x1b[201~';

      /// The program turns bracketed paste on.
      void bracketed() => terminal.write('\x1b[?2004h');

      /// What one bracketed paste of [text] sends between the markers.
      String pasted(String text) {
        sent.clear();
        terminal.paste(text);
        expect(sent, hasLength(1));
        final out = sent.single;
        expect(out, startsWith(start));
        expect(out, endsWith(end));
        return out.substring(start.length, out.length - end.length);
      }

      test('an end marker in the text cannot end the paste', () {
        bracketed();
        expect(pasted('echo hi${end}id\r'), 'echo hi[201~id\r');
      });

      test('the signal characters cannot end the paste', () {
        // The tty drops the input queued before ^C, ^Z or ^\, start marker
        // and all, and the rest would run as typed.
        bracketed();
        for (final c in ['\x03', '\x1a', '\x1c']) {
          expect(pasted('echo hi${c}id\r'), 'echo hiid\r');
        }
      });

      test('ESC, the other C0 controls, DEL and C1 go; tab, LF, CR stay', () {
        bracketed();
        expect(pasted('ls -l\r\x1b[A'), 'ls -l\r[A');
        expect(pasted('a\x00b\x07c\x08d\x7fe\x80f\x9bg\x9fh'), 'abcdefgh');
        expect(pasted('a\tb\nc\r'), 'a\tb\nc\r');
      });

      test('text with no control character passes as it is', () {
        bracketed();
        const text = 'ls -l | grep "x" ~ ä €  ÿ😀';
        expect(pasted(text), text);
        expect(pasted(''), '');
      });

      test('without bracketed paste the text goes as typed, unchanged', () {
        terminal.paste('ls$end\x03\r');
        expect(sent, ['ls$end\x03\r']);
      });

      test('several characters at once from the keyboard go as a paste', () {
        bracketed();
        terminal.textInput('ls -l\r');
        expect(sent, ['${start}ls -l\r$end']);
      });

      test('several characters from the keyboard lose the controls', () {
        terminal.textInput('a${end}b\x1c\r');
        bracketed();
        terminal.textInput('a${end}b\x1c\r');
        expect(sent, ['a${end}b\x1c\r', '${start}a[201~b\r$end']);
      });

      test(
        'one character from the keyboard is typed, also outside the BMP',
        () {
          bracketed();
          terminal.textInput('a');
          terminal.textInput('😀');
          expect(sent, ['a', '😀']);
        },
      );

      test('a paste does not use the sticky modifiers up', () {
        mods.toggleCtrl();
        terminal.textInput('cd');
        terminal.paste('x');
        expect(sent, ['cd', 'x']);
        expect(mods.ctrl, isTrue);
        terminal.textInput('c');
        expect(sent.last, '\x03');
      });

      testWidgets('what the phone keyboard commits goes through TerminalView', (
        tester,
      ) async {
        bracketed();
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: TerminalView(terminal))),
        );
        // A tap opens the phone keyboard.
        await tester.tap(find.byType(TerminalView));
        await tester.pump(kDoubleTapTimeout);
        expect(tester.testTextInput.hasAnyClients, isTrue);
        // Text the keyboard still composes goes nowhere yet.
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'ls',
            composing: TextRange(start: 0, end: 2),
            selection: TextSelection.collapsed(offset: 2),
          ),
        );
        await tester.pump();
        expect(sent, isEmpty);
        // A paste from the keyboard's clipboard comes as one commit.
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: 'ls$end -l\x1c\n',
            selection: const TextSelection.collapsed(offset: 12),
          ),
        );
        await tester.pump();
        expect(sent, ['${start}ls[201~ -l\n$end']);
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'q',
            selection: TextSelection.collapsed(offset: 1),
          ),
        );
        await tester.pump();
        expect(sent.last, 'q');
      });

      test('keeps exactly the characters that are no controls, in order', () {
        // The oracle: the rule spelled out, one code unit at a time.
        bool dropped(int c) =>
            (c < 0x20 && c != 0x09 && c != 0x0a && c != 0x0d) ||
            (c >= 0x7f && c <= 0x9f);
        String oracle(String s) =>
            String.fromCharCodes(s.codeUnits.where((c) => !dropped(c)));

        const pieces = [end, start, 'a', ' ', '~', 'ä', '😀', ' '];
        bracketed();
        for (var seed = 0; seed < 3000; seed++) {
          final random = Random(seed);
          final text = [
            for (var i = random.nextInt(24); i > 0; i--)
              random.nextBool()
                  ? pieces[random.nextInt(pieces.length)]
                  // Any code unit up to U+00FF: every control and the
                  // characters on both sides of each range.
                  : String.fromCharCode(random.nextInt(0x100)),
          ].join();
          final inner = pasted(text);
          expect(inner, oracle(text), reason: 'seed $seed');
          expect(inner.codeUnits.where(dropped), isEmpty, reason: 'seed $seed');
          expect(inner.contains('\x1b'), isFalse, reason: 'seed $seed');
          expect(pasted(inner), inner, reason: 'idempotent, seed $seed');
        }
      });
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
