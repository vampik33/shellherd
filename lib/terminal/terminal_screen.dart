import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../ssh/host.dart';
import '../ssh/ssh_connector.dart';
import '../ui/palette.dart';
import 'key_bar.dart';
import 'ssh_shell_session.dart';

/// A full terminal on [host] over SSH, with the key bar under it.
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    super.key,
    required this.host,
    required this.connector,
  });

  final Host host;
  final SshConnector connector;

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

sealed class _Phase {
  const _Phase();
}

class _Connecting extends _Phase {
  const _Connecting();
}

class _Open extends _Phase {
  const _Open();
}

class _Ended extends _Phase {
  const _Ended(this.end);
  final ShellEnd end;
}

class _Failed extends _Phase {
  const _Failed(this.error);
  final Object error;
}

class _TerminalScreenState extends State<TerminalScreen> {
  final _modifiers = StickyModifiers();
  late final _terminal = StickyTerminal(_modifiers);
  SshShellSession? _session;
  _Phase _phase = const _Connecting();

  /// Counts connection attempts, so a late result of an old one is dropped.
  int _attempt = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_connect());
  }

  Future<void> _connect() async {
    final attempt = ++_attempt;
    bool current() => mounted && attempt == _attempt;
    setState(() => _phase = const _Connecting());
    final SshShellSession session;
    try {
      final client = await widget.connector.open(widget.host);
      if (!current()) {
        client.close();
        return;
      }
      session = await SshShellSession.start(client, _terminal);
    } catch (e) {
      if (current()) setState(() => _phase = _Failed(e));
      return;
    }
    if (!current()) {
      session.close();
      return;
    }
    setState(() {
      _session = session;
      _phase = const _Open();
    });
    final end = await session.done;
    if (current()) setState(() => _phase = _Ended(end));
  }

  void _reconnect() {
    _modifiers.clear();
    _terminal.write('\r\n');
    unawaited(_connect());
  }

  @override
  void dispose() {
    _attempt++;
    _session?.close();
    _modifiers.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _theme.background,
      appBar: AppBar(
        title: Text(widget.host.label),
        actions: [_LinkChip(_phase), const SizedBox(width: 8)],
      ),
      body: SafeArea(
        child: Column(
          children: [
            ?_banner(),
            Expanded(
              child: TerminalView(
                _terminal,
                theme: _theme,
                autofocus: true,
                padding: const EdgeInsets.all(4),
              ),
            ),
            KeyBar(terminal: _terminal),
          ],
        ),
      ),
    );
  }

  Widget? _banner() => switch (_phase) {
    _Connecting() || _Open() => null,
    _Ended(:final end) => _Banner(
      end.lost
          ? 'Connection lost.'
          : 'Session ended'
                '${end.exitCode == null ? '' : ' (exit ${end.exitCode})'}.',
      action: ('Reconnect', _reconnect),
    ),
    _Failed(:final error) => _failure(error),
  };

  Widget _failure(Object error) {
    final host = widget.host;
    final retry = ('Retry', _reconnect);
    return switch (error) {
      // No way past a changed key here: the user forgets it on purpose.
      SshHostKeyChanged(:final trusted, :final presented) => _Banner(
        'The host key of ${host.address} changed.',
        detail:
            'Trusted: $trusted\nServer:  $presented\n'
            'If you expected this, edit the host and forget the old key.',
      ),
      SshHostKeyRejected() => _Banner(
        'The host key was not trusted.',
        action: retry,
      ),
      SshAuthFailed() => _Banner(
        'The server refused the key for ${host.user}@${host.address}.',
        action: retry,
      ),
      SshNetworkException(:final cause) => _Banner(
        'Cannot reach ${host.address}:${host.port}.',
        detail: '$cause',
        action: retry,
      ),
      TimeoutException() => _Banner(
        'The shell did not start in time.',
        action: retry,
      ),
      _ => _Banner('Cannot open the shell.', detail: '$error', action: retry),
    };
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.message, {this.detail, this.action});

  final String message;
  final String? detail;
  final (String, VoidCallback)? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message,
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                  if (detail case final detail?)
                    SelectableText(
                      detail,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: scheme.onErrorContainer,
                      ),
                    ),
                ],
              ),
            ),
            if (action case (final label, final onPressed))
              TextButton(onPressed: onPressed, child: Text(label)),
          ],
        ),
      ),
    );
  }
}

class _LinkChip extends StatelessWidget {
  const _LinkChip(this.phase);
  final _Phase phase;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (phase) {
      _Connecting() => ('connecting', _theme.yellow),
      _Open() => ('ssh', _theme.green),
      _Ended() || _Failed() => ('closed', _theme.red),
    };
    return Chip(
      label: Text(label),
      avatar: Icon(Icons.circle, size: 10, color: color),
      visualDensity: VisualDensity.compact,
    );
  }
}

/// The Catppuccin Mocha colours that herdr uses.
const _theme = TerminalTheme(
  cursor: Color(0xFFF5E0DC),
  selection: Color(0x66585B70),
  foreground: Mocha.text,
  background: Mocha.base,
  black: Color(0xFF45475A),
  red: Mocha.red,
  green: Color(0xFFA6E3A1),
  yellow: Color(0xFFF9E2AF),
  blue: Mocha.blue,
  magenta: Color(0xFFF5C2E7),
  cyan: Mocha.teal,
  white: Color(0xFFBAC2DE),
  brightBlack: Color(0xFF585B70),
  brightRed: Mocha.red,
  brightGreen: Color(0xFFA6E3A1),
  brightYellow: Color(0xFFF9E2AF),
  brightBlue: Mocha.blue,
  brightMagenta: Color(0xFFF5C2E7),
  brightCyan: Mocha.teal,
  brightWhite: Color(0xFFA6ADC8),
  searchHitBackground: Color(0xFFF9E2AF),
  searchHitBackgroundCurrent: Color(0xFFA6E3A1),
  searchHitForeground: Mocha.base,
);
