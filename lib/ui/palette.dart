import 'package:flutter/painting.dart';
import 'package:xterm/xterm.dart';

/// The Catppuccin Mocha colours that herdr uses, for the app and the
/// terminal.
abstract final class Mocha {
  static const base = Color(0xFF1E1E2E);
  static const text = Color(0xFFCDD6F4);
  static const blue = Color(0xFF89B4FA);
  static const teal = Color(0xFF94E2D5);
  static const red = Color(0xFFF38BA8);
  static const green = Color(0xFFA6E3A1);
  static const yellow = Color(0xFFF9E2AF);
  static const mantle = Color(0xFF181825);
  static const surface0 = Color(0xFF313244);
  static const surface1 = Color(0xFF45475A);
  static const overlay = Color(0xFF6C7086);
  static const subtext = Color(0xFFA6ADC8);
}

/// The Catppuccin Mocha colours that herdr uses.
const mochaTerminalTheme = TerminalTheme(
  cursor: Color(0xFFF5E0DC),
  selection: Color(0x66585B70),
  foreground: Mocha.text,
  background: Mocha.base,
  black: Mocha.surface1,
  red: Mocha.red,
  green: Mocha.green,
  yellow: Mocha.yellow,
  blue: Mocha.blue,
  magenta: Color(0xFFF5C2E7),
  cyan: Mocha.teal,
  white: Color(0xFFBAC2DE),
  brightBlack: Color(0xFF585B70),
  brightRed: Mocha.red,
  brightGreen: Mocha.green,
  brightYellow: Mocha.yellow,
  brightBlue: Mocha.blue,
  brightMagenta: Color(0xFFF5C2E7),
  brightCyan: Mocha.teal,
  brightWhite: Mocha.subtext,
  searchHitBackground: Mocha.yellow,
  searchHitBackgroundCurrent: Mocha.green,
  searchHitForeground: Mocha.base,
);
