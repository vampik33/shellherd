import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:xterm/xterm.dart';

/// How a shell session ended. [lost] means the connection dropped.
/// [exitCode] is null when the shell gave no exit status: the connection
/// was lost, a signal ended the shell, or the app closed it.
typedef ShellEnd = ({int? exitCode, bool lost});

/// A shell on the PC joined to a [Terminal]: over SSH or mosh.
abstract interface class ShellSession {
  /// Completes once, when the shell ends, the connection drops or [close]
  /// runs.
  Future<ShellEnd> get done;

  /// The app went to the background: Android may freeze it there.
  void appPaused();

  /// The app is back in front, maybe on another network.
  Future<void> appResumed();

  /// Ends the shell and closes the connection.
  void close();
}

/// A login shell on the PC in a PTY, joined to an xterm.dart [Terminal].
///
/// The session owns its [SSHClient] and closes it when the shell ends.
///
/// dartssh2 notices a closed connection but not a stalled one: its keepalive
/// waits for each reply with no deadline. So the session pings every
/// [pingEvery] itself, and a ping that gets no reply within [pingTimeout]
/// ends it as lost. While the app is away ([appPaused]) it does not judge:
/// Android can freeze the app, and a deadline that ran out meanwhile says
/// nothing about the link.
class SshShellSession implements ShellSession {
  SshShellSession._(
    this._client,
    this._shell,
    this.terminal,
    this.pingEvery,
    this.pingTimeout,
  );

  final SSHClient _client;
  final SSHSession _shell;
  final Terminal terminal;
  final Duration pingEvery;
  final Duration pingTimeout;
  final _subs = <StreamSubscription<String>>[];
  final _ended = Completer<ShellEnd>();
  Timer? _pinger;
  var _checking = false;

  /// Goes up with each [appPaused]: a ping from before it does not count.
  var _epoch = 0;

  /// Starts a shell with the size of [terminal] and joins the two. The
  /// terminal can come from an earlier session: its text stays, its modes
  /// go back to the defaults.
  ///
  /// It owns [client] from the call on: if the shell does not start within
  /// [timeout], or fails, it closes the client and throws.
  static Future<SshShellSession> start(
    SSHClient client,
    Terminal terminal, {
    Duration timeout = const Duration(seconds: 15),
    Duration pingEvery = const Duration(seconds: 15),
    Duration pingTimeout = const Duration(seconds: 20),
  }) async {
    resetTerminalModes(terminal);
    final SSHSession shell;
    final width = terminal.viewWidth;
    final height = terminal.viewHeight;
    try {
      // dartssh2 waits for a channel open with no deadline of its own.
      shell = await client
          .shell(
            pty: SSHPtyConfig(width: width, height: height),
          )
          .timeout(timeout);
    } catch (_) {
      client.close();
      rethrow;
    }
    final session = SshShellSession._(
      client,
      shell,
      terminal,
      pingEvery,
      pingTimeout,
    );
    session._attach();
    // The view can change size while the shell starts.
    if (terminal.viewWidth != width || terminal.viewHeight != height) {
      shell.resizeTerminal(terminal.viewWidth, terminal.viewHeight);
    }
    return session;
  }

  @override
  Future<ShellEnd> get done => _ended.future;

  void _attach() {
    for (final stream in [_shell.stdout, _shell.stderr]) {
      // One decoder for each stream: a UTF-8 character can span two chunks.
      _subs.add(
        stream
            .cast<List<int>>()
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(terminal.write),
      );
    }
    terminal.onOutput = _onOutput;
    terminal.onResize = _onResize;
    // dartssh2 completes done without an error also when the connection
    // drops; then the client is closed and there is no exit status.
    _shell.done.whenComplete(
      () => _end((
        exitCode: _shell.exitCode,
        lost: _shell.exitCode == null && _client.isClosed,
      )),
    );
    _startPinger();
  }

  void _startPinger() {
    if (_ended.isCompleted) return;
    _pinger ??= Timer.periodic(pingEvery, (_) => checkLink());
  }

  /// Stops the pings while the app is in the background, and drops the
  /// verdict of the one on its way.
  @override
  void appPaused() {
    _pinger?.cancel();
    _pinger = null;
    _epoch++;
    _checking = false;
  }

  /// Pings at once with a full deadline, and every [pingEvery] again.
  @override
  Future<void> appResumed() {
    _startPinger();
    return checkLink();
  }

  /// Pings the PC now, and ends the session as lost if no reply comes
  /// within [pingTimeout].
  Future<void> checkLink() async {
    if (_checking || _ended.isCompleted) return;
    _checking = true;
    final epoch = _epoch;
    try {
      await _client.ping().timeout(pingTimeout);
    } catch (_) {
      // A timeout, or the connection has closed under the ping.
      if (epoch == _epoch) _end((exitCode: null, lost: true));
    } finally {
      if (epoch == _epoch) _checking = false;
    }
  }

  void _onOutput(String data) {
    if (_ended.isCompleted) return;
    _shell.write(utf8.encode(data));
  }

  void _onResize(int width, int height, int pixelWidth, int pixelHeight) {
    if (_ended.isCompleted) return;
    _shell.resizeTerminal(width, height, pixelWidth, pixelHeight);
  }

  void _end(ShellEnd end) {
    if (_ended.isCompleted) return;
    _pinger?.cancel();
    // A new session can own the terminal by now; leave its callbacks.
    if (terminal.onOutput == _onOutput) terminal.onOutput = null;
    if (terminal.onResize == _onResize) terminal.onResize = null;
    _client.close();
    _ended.complete(end);
  }

  @override
  void close() {
    for (final s in _subs) {
      s.cancel();
    }
    _end((exitCode: null, lost: false));
  }
}

/// Turns off what a program of an earlier session left on: a program that
/// lost its connection (vim, less) never left the alternate screen or
/// turned off mouse reports or a hidden cursor. xterm.dart has no full
/// reset (RIS), so this sets each mode that it supports.
void resetTerminalModes(Terminal t) => t
  ..useMainBuffer()
  ..resetCursorStyle()
  ..setMargins(0)
  ..setCursorKeysMode(false)
  ..setAppKeypadMode(false)
  ..setReverseDisplayMode(false)
  ..setOriginMode(false)
  ..setAutoWrapMode(true)
  ..setMouseMode(MouseMode.none)
  ..setMouseReportMode(MouseReportMode.normal)
  ..setReportFocusMode(false)
  ..setAltBufferMouseScrollMode(false)
  ..setCursorVisibleMode(true)
  ..setCursorBlinkMode(false)
  ..setBracketedPasteMode(false)
  ..setInsertMode(false)
  ..setLineFeedMode(false)
  ..notifyListeners();
