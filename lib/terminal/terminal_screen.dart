import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../ssh/host.dart';
import '../ssh/ssh_connector.dart';
import '../ui/link_status.dart';
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
        actions: [_chip(), const SizedBox(width: 8)],
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

  LinkChip _chip() => switch (_phase) {
    _Connecting() => LinkChip('connecting', _theme.yellow),
    _Open() => LinkChip('ssh', _theme.green),
    _Ended() || _Failed() => LinkChip('closed', _theme.red),
  };

  Widget? _banner() => switch (_phase) {
    _Connecting() || _Open() => null,
    _Ended(:final end) => StatusBanner(
      end.lost
          ? 'Connection lost.'
          : 'Session ended'
                '${end.exitCode == null ? '' : ' (exit ${end.exitCode})'}.',
      action: ('Reconnect', _reconnect),
    ),
    _Failed(:final error) => _failure(error),
  };

  Widget _failure(Object error) {
    final retry = ('Retry', _reconnect);
    return switch (error) {
      SshConnectException() => sshFailureBanner(error, retry),
      TimeoutException() => StatusBanner(
        'The shell did not start in time.',
        action: retry,
      ),
      _ => StatusBanner(
        'Cannot open the shell.',
        detail: '$error',
        action: retry,
      ),
    };
  }
}

const _theme = mochaTerminalTheme;
