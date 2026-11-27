import 'package:flutter/painting.dart';

import '../../ui/palette.dart';

final _escape = RegExp(r'\x1b\[([0-9;:<=>?]*)[ -/]*([@-~])|\x1b');

/// Turns the text of `pane.read` with format `ansi` into one span per line.
/// herdr writes only colour and style sequences (SGR); others are dropped.
List<TextSpan> parseAnsi(String text) {
  final lines = <TextSpan>[];
  var line = <TextSpan>[];
  final sgr = _Sgr();

  void add(String part) {
    final pieces = part.replaceAll('\r', '').split('\n');
    for (var i = 0; i < pieces.length; i++) {
      if (i > 0) {
        lines.add(TextSpan(children: line));
        line = [];
      }
      if (pieces[i].isNotEmpty) {
        line.add(TextSpan(text: pieces[i], style: sgr.style));
      }
    }
  }

  var at = 0;
  for (final m in _escape.allMatches(text)) {
    add(text.substring(at, m.start));
    if (m[2] == 'm') sgr.apply(m[1]!);
    at = m.end;
  }
  add(text.substring(at));
  lines.add(TextSpan(children: line));
  return lines;
}

/// Whether [text] leaves a colour or style in force at its end: text
/// after it would take it.
bool ansiCarries(String text) {
  final sgr = _Sgr();
  for (final m in _escape.allMatches(text)) {
    if (m[2] == 'm') sgr.apply(m[1]!);
  }
  return !sgr.plain;
}

/// The colours and styles in force at one point of the text.
class _Sgr {
  Color? _fg;
  Color? _bg;
  var _bold = false;
  var _dim = false;
  var _italic = false;
  var _underline = false;
  var _strike = false;
  var _inverse = false;
  TextStyle? _style;

  TextStyle get style => _style ??= _build();

  /// No colour or style is in force.
  bool get plain =>
      _fg == null &&
      _bg == null &&
      !_bold &&
      !_dim &&
      !_italic &&
      !_underline &&
      !_strike &&
      !_inverse;

  TextStyle _build() {
    final fg = _inverse ? (_bg ?? _t.background) : (_fg ?? _t.foreground);
    return TextStyle(
      color: _dim ? fg.withValues(alpha: 0.6) : fg,
      backgroundColor: _inverse ? (_fg ?? _t.foreground) : _bg,
      fontWeight: _bold ? FontWeight.w700 : FontWeight.w400,
      fontStyle: _italic ? FontStyle.italic : FontStyle.normal,
      decoration: TextDecoration.combine([
        if (_underline) TextDecoration.underline,
        if (_strike) TextDecoration.lineThrough,
      ]),
    );
  }

  void apply(String params) {
    _style = null;
    final codes = params.isEmpty
        ? const [0]
        : [for (final p in params.split(';')) int.tryParse(p) ?? 0];
    for (var i = 0; i < codes.length; i++) {
      final c = codes[i];
      switch (c) {
        case 0:
          _fg = _bg = null;
          _bold = _dim = _italic = _underline = _strike = _inverse = false;
        case 1:
          _bold = true;
        case 2:
          _dim = true;
        case 3:
          _italic = true;
        case 4:
          _underline = true;
        case 7:
          _inverse = true;
        case 9:
          _strike = true;
        case 22:
          _bold = _dim = false;
        case 23:
          _italic = false;
        case 24:
          _underline = false;
        case 27:
          _inverse = false;
        case 29:
          _strike = false;
        case >= 30 && <= 37:
          _fg = _basic[c - 30];
        case 39:
          _fg = null;
        case >= 40 && <= 47:
          _bg = _basic[c - 40];
        case 49:
          _bg = null;
        case >= 90 && <= 97:
          _fg = _basic[c - 90 + 8];
        case >= 100 && <= 107:
          _bg = _basic[c - 100 + 8];
        case 38 || 48:
          final (color, used) = _extended(codes, i + 1);
          if (c == 38) {
            _fg = color ?? _fg;
          } else {
            _bg = color ?? _bg;
          }
          i += used;
      }
    }
  }

  /// A 256-colour or RGB colour that starts at [at], and how many codes it
  /// took.
  static (Color?, int) _extended(List<int> codes, int at) {
    if (at >= codes.length) return (null, 0);
    if (codes[at] == 5 && at + 1 < codes.length) {
      return (_indexed(codes[at + 1]), 2);
    }
    if (codes[at] == 2 && at + 3 < codes.length) {
      return (
        Color.fromARGB(255, codes[at + 1], codes[at + 2], codes[at + 3]),
        4,
      );
    }
    return (null, codes.length - at);
  }

  static Color? _indexed(int n) {
    if (n < 0 || n > 255) return null;
    if (n < 16) return _basic[n];
    if (n >= 232) {
      final v = 8 + (n - 232) * 10;
      return Color.fromARGB(255, v, v, v);
    }
    int level(int l) => l == 0 ? 0 : 55 + l * 40;
    final i = n - 16;
    return Color.fromARGB(
      255,
      level(i ~/ 36),
      level(i ~/ 6 % 6),
      level(i % 6),
    );
  }

  static const _t = graphiteTerminalTheme;
  static final _basic = [
    _t.black,
    _t.red,
    _t.green,
    _t.yellow,
    _t.blue,
    _t.magenta,
    _t.cyan,
    _t.white,
    _t.brightBlack,
    _t.brightRed,
    _t.brightGreen,
    _t.brightYellow,
    _t.brightBlue,
    _t.brightMagenta,
    _t.brightCyan,
    _t.brightWhite,
  ];
}
