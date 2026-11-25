import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../ui/palette.dart';

/// Ctrl and alt from the key bar. A tap turns one on for the next key only.
class StickyModifiers extends ChangeNotifier {
  bool _ctrl = false;
  bool _alt = false;

  bool get ctrl => _ctrl;
  bool get alt => _alt;

  void toggleCtrl() {
    _ctrl = !_ctrl;
    notifyListeners();
  }

  void toggleAlt() {
    _alt = !_alt;
    notifyListeners();
  }

  void clear() {
    if (!_ctrl && !_alt) return;
    _ctrl = _alt = false;
    notifyListeners();
  }

  /// Applies the modifiers to typed [text] and clears them: ctrl turns the
  /// first character into its control code, alt puts ESC in front.
  String apply(String text) {
    if (text.isEmpty || (!_ctrl && !_alt)) return text;
    var out = text;
    if (_ctrl) {
      final code = _ctrlCode(text.runes.first);
      if (code != null) {
        out =
            String.fromCharCode(code) +
            String.fromCharCodes(text.runes.skip(1));
      }
    }
    if (_alt) out = '\x1b$out';
    clear();
    return out;
  }

  static int? _ctrlCode(int c) => switch (c) {
    >= 0x40 && <= 0x5f => c - 0x40, // @ A-Z [ \ ] ^ _
    >= 0x61 && <= 0x7a => c - 0x60, // a-z
    0x20 => 0, // ctrl+space
    0x3f => 0x7f, // ctrl+?
    _ => null,
  };
}

/// A [Terminal] that adds the sticky [modifiers] to the next key from the
/// phone keyboard or the key bar. Replies of the terminal to the program
/// (cursor reports, device attributes) do not go through here, so the
/// modifiers never change them.
class StickyTerminal extends Terminal {
  StickyTerminal(this.modifiers, {super.maxLines = 10000});

  final StickyModifiers modifiers;

  @override
  bool keyInput(
    TerminalKey key, {
    bool shift = false,
    bool alt = false,
    bool ctrl = false,
  }) {
    final handled = super.keyInput(
      key,
      shift: shift,
      alt: alt || modifiers.alt,
      ctrl: ctrl || modifiers.ctrl,
    );
    // A key that gives no output (a letter without modifiers) comes back
    // as textInput; the modifiers must stay on for it.
    if (handled) modifiers.clear();
    return handled;
  }

  /// Text from the phone keyboard or the key bar. More than one character
  /// at once is not a typed key but a paste from the keyboard's clipboard,
  /// or text it composed: it goes as [paste], without the sticky modifiers,
  /// which stay on for the next key.
  @override
  void textInput(String text) {
    if (text.runes.length > 1) {
      paste(text);
    } else {
      super.textInput(modifiers.apply(text));
    }
  }

  /// xterm.dart puts pasted text between the bracketed paste markers as it
  /// is, and some control characters in it would end the paste early: the
  /// program would take the rest as typed, so a newline in it would run a
  /// command. ESC starts the end marker; the tty's signal characters (^C, ^Z
  /// and ^\ by default) make it drop the input queued before them, start
  /// marker and all. So a bracketed paste drops [_pasteControls].
  ///
  /// Without bracketed paste, xterm.dart's paste hands the text to
  /// [textInput], which would hand it back here; it goes out directly.
  @override
  void paste(String text) {
    if (bracketedPasteMode) {
      super.paste(text.replaceAll(_pasteControls, ''));
    } else {
      super.textInput(text);
    }
  }
}

/// The control characters a bracketed paste drops: C0 but tab, newline and
/// carriage return, DEL, and C1.
final _pasteControls = RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]');

/// The keys that a phone keyboard does not have. It scrolls sideways.
class KeyBar extends StatelessWidget {
  const KeyBar({super.key, required this.terminal});

  final StickyTerminal terminal;

  @override
  Widget build(BuildContext context) {
    final mods = terminal.modifiers;
    _Key key(String label, TerminalKey key) =>
        _Key(label, onTap: () => terminal.keyInput(key));
    _Key text(String label) =>
        _Key(label, onTap: () => terminal.textInput(label));
    // Only the modifier keys change when a modifier turns on or off.
    Widget modifier(String label, bool Function() on, VoidCallback toggle) =>
        ListenableBuilder(
          listenable: mods,
          builder: (context, _) => _Key(label, on: on(), onTap: toggle),
        );
    return _KeyRow([
      key('esc', TerminalKey.escape),
      key('tab', TerminalKey.tab),
      modifier('ctrl', () => mods.ctrl, mods.toggleCtrl),
      modifier('alt', () => mods.alt, mods.toggleAlt),
      key('↑', TerminalKey.arrowUp),
      key('↓', TerminalKey.arrowDown),
      key('←', TerminalKey.arrowLeft),
      key('→', TerminalKey.arrowRight),
      text('|'),
      text('~'),
    ]);
  }
}

/// Keys for a herdr pane: each sends one herdr key name.
class HerdrKeys extends StatelessWidget {
  const HerdrKeys(this.keys, {super.key, required this.onKey});

  /// Label and herdr key name of each key.
  final List<(String, String)> keys;
  final void Function(String key) onKey;

  @override
  Widget build(BuildContext context) => _KeyRow([
    for (final (label, key) in keys) _Key(label, onTap: () => onKey(key)),
  ]);
}

class _KeyRow extends StatelessWidget {
  const _KeyRow(this.keys);

  final List<Widget> keys;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: ListView(scrollDirection: Axis.horizontal, children: keys),
  );
}

class _Key extends StatelessWidget {
  const _Key(this.label, {required this.onTap, this.on = false});

  final String label;
  final VoidCallback onTap;
  final bool on;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
      child: Material(
        color: on ? scheme.primary : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          // The text input keeps the focus, so the phone keyboard stays open.
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 44),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              label,
              style: TextStyle(
                fontFamily: monoFont,
                color: on ? scheme.onPrimary : scheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
