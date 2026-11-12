import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../ssh/host.dart';
import '../ssh/ssh_connector.dart';
import '../ui/link_status.dart';
import '../ui/palette.dart';
import 'key_bar.dart';
import 'mosh_shell_session.dart';
import 'ssh_shell_session.dart';

/// A full terminal on [host] over SSH or mosh, with the key bar under it.
class TerminalScreen extends StatefulWidget {
  const TerminalScreen({
    super.key,
    required this.host,
    required this.connector,
    this.mosh = false,
  });

  final Host host;
  final SshConnector connector;

  /// Over mosh: SSH only starts mosh-server.
  final bool mosh;

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
  ShellSession? _session;
  _Phase _phase = const _Connecting();
  late final AppLifecycleListener _lifecycle;

  /// Counts connection attempts, so a late result of an old one is dropped.
  int _attempt = 0;

  /// The app is in the background: a session that comes up meanwhile
  /// starts paused.
  var _paused = false;

  @override
  void initState() {
    super.initState();
    // The network can change while the app is away; mosh moves along, and
    // an SSH link that died meanwhile shows as lost at once.
    _lifecycle = AppLifecycleListener(
      onPause: () {
        _paused = true;
        _session?.appPaused();
      },
      onResume: () {
        _paused = false;
        if (_session case final session?) unawaited(session.appResumed());
      },
    );
    unawaited(_connect());
  }

  Future<void> _connect() async {
    final attempt = ++_attempt;
    bool current() => mounted && attempt == _attempt;
    setState(() => _phase = const _Connecting());
    final ShellSession session;
    try {
      session = widget.mosh
          ? await MoshShellSession.start(
              ssh: () => widget.connector.open(widget.host),
              host: widget.host,
              terminal: _terminal,
            )
          : await _startSsh();
    } catch (e) {
      if (current()) setState(() => _phase = _Failed(e));
      return;
    }
    if (!current()) {
      session.close();
      return;
    }
    if (_paused) session.appPaused();
    setState(() {
      _session = session;
      _phase = const _Open();
    });
    final end = await session.done;
    if (current()) setState(() => _phase = _Ended(end));
  }

  Future<ShellSession> _startSsh() async =>
      SshShellSession.start(await widget.connector.open(widget.host), _terminal);

  void _reconnect() {
    _modifiers.clear();
    _terminal.write('\r\n');
    unawaited(_connect());
  }

  @override
  void dispose() {
    _attempt++;
    _lifecycle.dispose();
    _session?.close();
    _modifiers.dispose();
    super.dispose();
  }

  MoshLinkStatus? get _moshLink => switch ((_phase, _session)) {
    (_Open(), final MoshShellSession mosh) => mosh.link.value,
    _ => null,
  };

  /// [build] again on each change of the mosh link: only the chip and the
  /// banner follow it, not the terminal.
  Widget _followingLink(Widget Function() build) => switch (_session) {
    final MoshShellSession mosh => ListenableBuilder(
      listenable: mosh.link,
      builder: (_, _) => build(),
    ),
    _ => build(),
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _theme.background,
      appBar: AppBar(
        title: Text(widget.host.label),
        actions: linkActions(context, _followingLink(_chip)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            _followingLink(() => _banner() ?? const SizedBox.shrink()),
            Expanded(
              child: TerminalView(
                _terminal,
                theme: _theme,
                textStyle: const TerminalStyle(fontFamily: monoFont),
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

  LinkChip _chip() => switch ((_phase, _moshLink)) {
    (_Connecting(), _) => LinkChip('connecting', _theme.yellow),
    (_Open(), null) => LinkChip('ssh', _theme.green),
    (_Open(), (link: MoshLink.live, :final rtt)) => LinkChip(
      rtt == null ? 'mosh' : 'mosh · ${rtt.inMilliseconds} ms',
      _theme.green,
    ),
    (_Open(), (link: MoshLink.connecting, rtt: _)) => LinkChip(
      'mosh',
      _theme.yellow,
    ),
    (_Open(), _) => LinkChip('mosh · waiting', _theme.yellow),
    (_Ended() || _Failed(), _) => LinkChip('closed', _theme.red),
  };

  Widget? _banner() => switch (_phase) {
    _Connecting() => null,
    _Open() => switch (_moshLink?.link) {
      MoshLink.silent => StatusBanner(
        'No answer from mosh-server. A firewall may block UDP '
        '(mosh uses ports 60000 to 61000).',
      ),
      MoshLink.stale => const StatusBanner(
        'No link. The session waits on the PC and catches up when the link '
        'is back.',
      ),
      _ => null,
    },
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
      MoshServerMissing(:final path) => StatusBanner(
        'mosh-server is not installed on ${widget.host.label}, or not at '
        '"$path".',
        action: retry,
      ),
      MoshStartFailed(:final output) => StatusBanner(
        'mosh-server did not start.',
        detail: output,
        action: retry,
      ),
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

const _theme = graphiteTerminalTheme;
