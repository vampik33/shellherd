import 'package:flutter/painting.dart';
import 'package:xterm/xterm.dart';

/// Herdr app's default dark theme, graphite, with the panel colours that
/// herdr-app works out from it (settings.rs `resolve`). Names follow
/// herdr-app's theme keys.
abstract final class Graphite {
  /// Terminal and screen background (`background`, `surface`).
  static const background = Color(0xFF17191D);

  /// Text of the panels (`foreground`).
  static const foreground = Color(0xFFEEEEEF);

  /// Text in a terminal (`terminal_foreground`).
  static const terminalForeground = Color(0xFFD2D4D9);

  /// Sidebars and bars (`chrome`).
  static const chrome = Color(0xFF101114);

  /// Behind cards (`canvas`).
  static const canvas = Color(0xFF131518);

  /// Menus and dialogs (`popover`).
  static const popover = Color(0xFF25272B);

  /// Raised controls (`raised`).
  static const raised = Color(0xFF2C2E31);

  /// A selected row, drawn over its background (`selected`).
  static const selected = Color(0x17FFFFFF);

  /// Dividers and outlines (`border`).
  static const border = Color(0x18FFFFFF);

  /// Secondary text (`muted`).
  static const muted = Color(0xFF98999B);

  /// Faint text (`dim`).
  static const dim = Color(0xFF696A6D);

  /// Links and primary actions (`accent`, ansi blue).
  static const accent = Color(0xFF96B2D7);

  /// Agent states (`working`, `blocked`, `done`, `idle`).
  static const working = Color(0xFFE5C07B);
  static const blocked = Color(0xFFF0705F);
  static const done = Color(0xFF76A8FF);
  static const idle = dim;

  /// ANSI colours used outside the terminal.
  static const red = Color(0xFFDC8C95);
  static const green = Color(0xFFA6BD91);
  static const yellow = Color(0xFFD8BE87);
  static const cyan = Color(0xFF8CBDC3);
  static const brightRed = Color(0xFFF0A5AD);

  /// Behind an error: the background with a fifth of ansi red.
  static const errorContainer = Color(0xFF3E3035);
}

/// The font of Herdr app's panels.
const uiFont = 'Geist';

/// The font of Herdr app's terminals.
const monoFont = 'JetBrains Mono';

/// Herdr app's graphite terminal palette.
const graphiteTerminalTheme = TerminalTheme(
  cursor: Graphite.terminalForeground,
  // xterm draws the selection over the text, so it must let the text through.
  selection: Color(0x99394454),
  foreground: Graphite.terminalForeground,
  background: Graphite.background,
  black: Color(0xFF45484F),
  red: Graphite.red,
  green: Graphite.green,
  yellow: Graphite.yellow,
  blue: Graphite.accent,
  magenta: Color(0xFFB5A2CE),
  cyan: Graphite.cyan,
  white: Graphite.terminalForeground,
  brightBlack: Color(0xFF818793),
  brightRed: Graphite.brightRed,
  brightGreen: Color(0xFFBAD5A2),
  brightYellow: Color(0xFFEAD2A1),
  brightBlue: Color(0xFFB0CBEF),
  brightMagenta: Color(0xFFCBB7E6),
  brightCyan: Color(0xFFA4D5DB),
  brightWhite: Color(0xFFF0F0F2),
  searchHitBackground: Graphite.working,
  searchHitBackgroundCurrent: Graphite.done,
  searchHitForeground: Graphite.background,
);
