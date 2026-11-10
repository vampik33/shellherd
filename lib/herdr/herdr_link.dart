import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import 'api/herdr_client.dart';

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
  /// socket its cause is an [SSHChannelOpenError]. Throws
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
        herdrSocketPath(await _remoteConfigDir(ssh, timeout), session: session);
    final client = HerdrClient(sshDialer(ssh, path), timeout: timeout);
    return HerdrLink._(path, client, await client.ping());
  }

  static const _marker = 'SHELLHERD_CONFIG_DIR=';
  static const _lookup = 'config dir lookup';

  /// herdr keeps its socket under `${XDG_CONFIG_HOME:-$HOME/.config}/herdr`.
  ///
  /// The command runs through `sh -c`, because the login shell of the user
  /// can be fish. The marker skips any text that shell startup files print.
  static Future<String> _remoteConfigDir(
    SSHClient ssh,
    Duration timeout,
  ) async {
    const cmd =
        r"""sh -c 'printf "\n%s%s\n" """ +
        _marker +
        r""" "${XDG_CONFIG_HOME:-$HOME/.config}"'""";
    final String out;
    try {
      out = await _run(ssh, cmd, timeout);
    } on HerdrException {
      rethrow;
    } catch (e) {
      throw HerdrConnectException(_lookup, e);
    }
    final dir =
        LineSplitter.split(out)
            .where((l) => l.startsWith(_marker))
            .map((l) => l.substring(_marker.length))
            .lastOrNull ??
        '';
    if (!dir.startsWith('/')) {
      throw HerdrConnectException(_lookup, 'unexpected output: ${out.trim()}');
    }
    return dir;
  }

  /// Runs [cmd] and returns its stdout. Not [SSHClient.run]: that has no
  /// deadline and leaves stdin open. Here stdin gets EOF at once, so a
  /// startup file that reads it cannot block, and a shell that hangs anyway
  /// fails after [timeout].
  static Future<String> _run(
    SSHClient ssh,
    String cmd,
    Duration timeout,
  ) async {
    final session = await openWithin(
      ssh.execute(cmd),
      timeout,
      (s) => s.channel.destroy(),
      _lookup,
    );
    try {
      await session.stdin.close();
      return await utf8.decoder.bind(session.stdout).join().timeout(timeout);
    } on TimeoutException {
      throw HerdrTimeoutException(_lookup, timeout);
    } finally {
      session.channel.destroy();
    }
  }
}

/// Path of the herdr API socket under the remote [configDir]:
/// `herdr/herdr.sock`, or `herdr/sessions/<session>/herdr.sock`.
String herdrSocketPath(String configDir, {String? session}) {
  if (session == null) return '$configDir/herdr/herdr.sock';
  if (session.isEmpty ||
      session.contains('/') ||
      session == '.' ||
      session == '..') {
    throw ArgumentError.value(session, 'session', 'not a herdr session name');
  }
  return '$configDir/herdr/sessions/$session/herdr.sock';
}
