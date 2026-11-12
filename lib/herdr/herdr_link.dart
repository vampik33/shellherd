import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import '../ssh/ssh_exec.dart';
import 'api/herdr_client.dart';
import 'pane_stream.dart';

/// A [HerdrDialer] that reaches the herdr socket at [socketPath] on the
/// remote host through [ssh].
///
/// [HerdrClient] calls it once for each request and once for each
/// subscription. Every call opens a new `direct-streamlocal@openssh.com`
/// channel on the same SSH connection. A stalled connection never answers
/// the open (dartssh2's keepalive has no reply deadline), so [HerdrClient]
/// bounds each dial with its timeout.
HerdrDialer sshDialer(SSHClient ssh, String socketPath) =>
    () async => _SshHerdrChannel(await ssh.forwardLocalUnix(socketPath));

class _SshHerdrChannel implements HerdrChannel {
  _SshHerdrChannel(this._channel);
  final SSHForwardChannel _channel;

  @override
  Stream<List<int>> get input => _channel.stream;

  @override
  void write(List<int> bytes) => _channel.sink.add(bytes);

  /// Closes both directions at once, like the local socket's `destroy`.
  /// [HerdrClient] calls this only when it needs no more data, so there is
  /// no reason to wait for herdr to close its side.
  @override
  Future<void> close() async => _channel.destroy();
}

/// The herdr server on a remote host, reached over one SSH connection.
///
/// The link does not own the SSH connection: the terminal can share it, and
/// the caller closes it. [HerdrLink] only finds the socket and checks that
/// herdr answers.
class HerdrLink {
  HerdrLink._(this.socketPath, this.client, this.server);

  /// Absolute path of the herdr API socket on the remote host.
  final String socketPath;

  final HerdrClient client;

  /// The `ping` reply from [connect]: herdr version, protocol, capabilities.
  final HerdrPing server;

  /// Finds the socket of herdr [session] (the default session if null) on
  /// the remote host and pings it. [socketPath] skips the lookup.
  ///
  /// Throws [HerdrConnectException] when the remote shell does not give the
  /// config directory, or when no herdr socket answers. For a missing
  /// socket it is a [HerdrNoSocketException], whose cause is an
  /// [SSHChannelOpenError]. Throws
  /// [HerdrTimeoutException] when the remote shell or herdr does not answer
  /// within [timeout].
  static Future<HerdrLink> connect(
    SSHClient ssh, {
    String? session,
    String? socketPath,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final path =
        socketPath ??
        herdrSocketPath(
          await remoteDir(
            ssh,
            r'${XDG_CONFIG_HOME:-$HOME/.config}',
            what: 'config dir lookup',
            timeout: timeout,
          ),
          session: session,
        );
    final client = HerdrClient(sshDialer(ssh, path), timeout: timeout);
    final server = await withSocketPath(path, client.ping);
    return HerdrLink._(path, client, server);
  }
}

/// Runs [connect], and names [socketPath] when no server listens there:
/// the channel to it did not open, which is a [HerdrNoSocketException].
Future<T> withSocketPath<T>(
  String socketPath,
  Future<T> Function() connect,
) async {
  try {
    return await connect();
  } on HerdrConnectException catch (e) {
    if (e.cause is! SSHChannelOpenError) rethrow;
    throw HerdrNoSocketException(socketPath, e.method, e.cause);
  }
}

const _marker = 'SHELLHERD_DIR=';

/// The absolute directory that the shell [expression] gives on the remote
/// host, for example `${XDG_CONFIG_HOME:-$HOME/.config}`. [what] names the
/// lookup in errors. Throws as [remoteValue] does.
Future<String> remoteDir(
  SSHClient ssh,
  String expression, {
  required String what,
  required Duration timeout,
}) => remoteValue(
  ssh,
  expression,
  (v) => v.startsWith('/') ? v : null,
  what: what,
  timeout: timeout,
);

/// What [parse] makes of the text that the shell [expression] gives on the
/// remote host. [what] names the lookup in errors.
///
/// The command runs through `sh -c`, because the login shell of the user
/// can be fish. The marker skips any text that shell startup files print.
/// Throws [HerdrConnectException] when [parse] returns null, and
/// [HerdrTimeoutException] when the shell does not answer within [timeout].
Future<T> remoteValue<T extends Object>(
  SSHClient ssh,
  String expression,
  T? Function(String value) parse, {
  required String what,
  required Duration timeout,
}) async {
  if (expression.contains("'")) {
    throw ArgumentError.value(expression, 'expression', 'holds a quote');
  }
  final cmd = 'sh -c \'printf "\\n%s%s\\n" $_marker "$expression"\'';
  final String out;
  try {
    (out, _) = await sshExec(ssh, cmd, timeout);
  } on TimeoutException {
    throw HerdrTimeoutException(what, timeout);
  } catch (e) {
    throw HerdrConnectException(what, e);
  }
  final value = LineSplitter.split(out)
      .where((l) => l.startsWith(_marker))
      .map((l) => l.substring(_marker.length))
      .lastOrNull;
  final parsed = value == null ? null : parse(value);
  if (parsed == null) {
    throw HerdrConnectException(what, 'unexpected output: ${out.trim()}');
  }
  return parsed;
}

/// herdr's validate_name: ASCII letters, digits, . _ -, up to 64 bytes.
final _herdrSession = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

/// Path of the herdr API socket under the remote [configDir]:
/// `herdr/herdr.sock` for the default session (null or `default`, as herdr
/// names it), else `herdr/sessions/<session>/herdr.sock`. Throws
/// [ArgumentError] for a name herdr refuses.
String herdrSocketPath(String configDir, {String? session}) {
  if (session == null || session == 'default') {
    return '$configDir/herdr/herdr.sock';
  }
  if (session == '.' || session == '..' || !_herdrSession.hasMatch(session)) {
    throw ArgumentError.value(session, 'session', 'not a herdr session name');
  }
  return '$configDir/herdr/sessions/$session/herdr.sock';
}

/// A [ScreenOpener] that runs [observeCommand] on the remote host for the
/// herdr server at [socketPath], each observer on its own exec channel.
ScreenOpener sshScreenOpener(
  SSHClient ssh,
  String socketPath, {
  Duration timeout = const Duration(seconds: 15),
}) => (paneId, size) async => _SshScreenChannel(
  await openExec(ssh, observeCommand(socketPath, paneId, size), timeout),
);

class _SshScreenChannel implements ScreenChannel {
  _SshScreenChannel(this._session) {
    _stderr = utf8.decoder
        .bind(_session.stderr)
        .join()
        .catchError((Object _) => '');
  }

  final SSHSession _session;
  late final Future<String> _stderr;

  /// stdout, then an error that names the exit code and what the command
  /// wrote to stderr when it failed.
  @override
  Stream<List<int>> get output async* {
    yield* _session.stdout;
    await _session.done.timeout(const Duration(seconds: 5), onTimeout: () {});
    final code = _session.exitCode;
    if (code != null && code != 0) {
      throw HerdrConnectException(
        'terminal session observe',
        'exit $code: ${(await _stderr).trim()}',
      );
    }
  }

  /// Ends stdin first: the command stops herdr when stdin ends, which it
  /// also does when the SSH connection goes.
  @override
  void close() {
    unawaited(_session.stdin.close().catchError((Object _) {}));
    _session.channel.destroy();
  }
}

/// Characters herdr uses in pane ids. Only these reach the command: a
/// quote or a backslash would also break the quoting for fish, which reads
/// both inside single quotes.
final _paneTarget = RegExp(r'^[A-Za-z0-9:_.-]{1,128}$');

/// Runs `herdr terminal session observe` for [paneId] at [size] on the
/// remote host, through `sh` because the login shell can be fish. It finds
/// herdr on the PATH, else in `~/.local/bin`, where its installer puts it.
///
/// HERDR_SOCKET_PATH points herdr at the API socket the link uses: herdr
/// derives the socket of its screen stream from it, so a named session or
/// a socket set by hand needs no flag.
///
/// An observer that loses its reader keeps running until the pane prints
/// again, maybe never. So the command watches its stdin, which ends when
/// the app closes the channel or the SSH connection goes, and stops herdr
/// then.
String observeCommand(String socketPath, String paneId, PaneSize size) {
  if (!_paneTarget.hasMatch(paneId)) {
    throw ArgumentError.value(paneId, 'paneId', 'not a herdr pane id');
  }
  final inner = [
    'HERDR_SOCKET_PATH=${shQuote(socketPath)}',
    'export HERDR_SOCKET_PATH',
    'for h in herdr "\$HOME/.local/bin/herdr"; do',
    '  command -v "\$h" >/dev/null 2>&1 || continue',
    '  exec 3<&0',
    '  "\$h" terminal session observe $paneId'
        ' --cols ${size.cols} --rows ${size.rows} </dev/null 3<&- &',
    '  p=\$!',
    '  { cat <&3 >/dev/null 2>&1; kill \$p 2>/dev/null; } >/dev/null 2>&1 &',
    '  w=\$!',
    '  exec 3<&-',
    '  wait \$p; s=\$?',
    '  kill \$w 2>/dev/null',
    '  exit \$s',
    'done',
    'echo "herdr is not on the PATH or in ~/.local/bin" >&2',
    'exit 127',
  ].join('\n');
  return 'sh -c ${shQuote(inner)}';
}
