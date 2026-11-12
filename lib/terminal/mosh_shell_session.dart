import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mosh/dart_mosh.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../ssh/host.dart';
import '../ssh/ids.dart';
import '../ssh/ssh_exec.dart';
import '../ssh/ssh_connector.dart';
import 'ssh_shell_session.dart';

/// How the mosh link is.
enum MoshLink {
  /// Waiting for the first packet from mosh-server.
  connecting,

  /// Packets arrive.
  live,

  /// No packet ever came: UDP may be blocked on the way.
  silent,

  /// Packets came, but none lately. mosh keeps the session meanwhile.
  stale,
}

/// [MoshLink] and the round trip time, if one was measured.
typedef MoshLinkStatus = ({MoshLink link, Duration? rtt});

/// mosh-server did not start.
sealed class MoshStartException implements Exception {
  const MoshStartException();
}

/// The shell found no mosh-server under [path].
class MoshServerMissing extends MoshStartException {
  const MoshServerMissing(this.path);
  final String path;

  @override
  String toString() => 'MoshServerMissing($path)';
}

/// mosh-server printed no `MOSH CONNECT` line; [output] is what it printed.
class MoshStartFailed extends MoshStartException {
  const MoshStartFailed(this.output);
  final String output;

  @override
  String toString() => 'MoshStartFailed: $output';
}

/// What mosh-server printed when it started.
class MoshStart {
  const MoshStart({required this.port, required this.key, this.pid});

  final int port;
  final MoshKey key;

  /// The process id of the detached server, to end it with the screen.
  final int? pid;
}

/// A mosh-server that hears nothing from the app for this long exits, so a
/// session that the app lost (killed, phone gone) does not stay forever.
const moshServerTimeout = Duration(hours: 24);

/// The environment variable that marks the mosh-server of one session.
const _idVariable = 'SHELLHERD_MOSH_ID';

/// Starts mosh-server through `sh`, as the login shell can be fish. `-s`
/// makes it listen on the address the SSH connection came in on; `-l`
/// gives the shell a UTF-8 locale if the PC has none by default. [id] goes
/// into its environment, for [moshKillCommand].
String moshStartCommand(String moshServer, String id) {
  final server = moshServer.startsWith('~/')
      ? '"\$HOME"/${shQuote(moshServer.substring(2))}'
      : shQuote(moshServer);
  final inner =
      '$_idVariable=$id '
      'MOSH_SERVER_NETWORK_TMOUT=${moshServerTimeout.inSeconds} '
      'exec $server new -s -c 256 -l LANG=C.UTF-8 2>&1';
  return 'sh -c ${shQuote(inner)}';
}

/// Ends [pid] only if it is the mosh-server started with [id]: once that
/// server has exited, another process, even another mosh-server, can have
/// its pid. It needs /proc, so on a PC without one it ends nothing, and the
/// server exits after [moshServerTimeout].
String moshKillCommand(int pid, String id) => 'sh -c ${shQuote(
  "{ tr '\\0' '\\n' < /proc/$pid/environ; } 2>/dev/null "
  '| grep -qxF $_idVariable=$id && kill $pid',
)}';

/// Reads the output of [moshStartCommand]. Throws a [MoshStartException].
MoshStart parseMoshStart(String output, {int? exitCode, required String path}) {
  final MoshServerConfig config;
  try {
    config = MoshServerConfig.parse(output, host: '');
    // A FormatException comes from a key that is not base64; its message
    // quotes the key.
  } on Exception {
    if (exitCode == 127) throw MoshServerMissing(path);
    final lines = LineSplitter.split(output)
        // A connect line that did not parse still holds the session key.
        .where((l) => !l.contains('MOSH CONNECT') && l.trim().isNotEmpty)
        .toList();
    throw MoshStartFailed(
      lines.skip(lines.length > 5 ? lines.length - 5 : 0).join('\n'),
    );
  }
  final pid = RegExp(r'pid = (\d+)').firstMatch(output)?.group(1);
  return MoshStart(
    port: config.port,
    key: config.key,
    pid: pid == null ? null : int.parse(pid),
  );
}

/// A shell on the PC over mosh, joined to an xterm.dart [Terminal].
///
/// SSH only starts mosh-server; after that the session is UDP, and it lives
/// on while the network is gone. mosh sends the screen, not a byte stream,
/// so the text above the screen is not kept by the server.
class MoshShellSession implements ShellSession {
  MoshShellSession._(this._udp, this.terminal, this._heard, this._killServer);

  final MoshSession _udp;
  final Terminal terminal;
  final _Heard _heard;
  final Future<void> Function() _killServer;
  final _ended = Completer<ShellEnd>();
  late final StreamSubscription<String> _output;
  late final Timer _tick;

  /// The link, updated each second.
  final link = ValueNotifier<MoshLinkStatus>((
    link: MoshLink.connecting,
    rtt: null,
  ));

  /// How long without a packet makes the link [MoshLink.stale]. The server
  /// sends one at least every 3 s.
  static const staleAfter = Duration(seconds: 7);

  /// How long without a first packet makes it [MoshLink.silent].
  static const silentAfter = Duration(seconds: 10);

  /// Starts mosh-server over a connection from [ssh], which it closes, and
  /// joins the session to [terminal]. The terminal can come from an earlier
  /// session: its text stays, its modes go back to the defaults.
  static Future<MoshShellSession> start({
    required Future<SSHClient> Function() ssh,
    required Host host,
    required Terminal terminal,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    resetTerminalModes(terminal);
    final MoshStart started;
    final id = randomId();
    final client = await ssh();
    // mosh-server listens where this connection came in; a name can
    // resolve to other addresses as well.
    final peer = sshPeerAddress(client);
    try {
      final (output, exitCode) = await sshExec(
        client,
        moshStartCommand(host.moshServer, id),
        timeout,
      );
      started = parseMoshStart(
        output,
        exitCode: exitCode,
        path: host.moshServer,
      );
    } finally {
      client.close();
    }
    Future<void> kill() async {
      final pid = started.pid;
      if (pid == null) return;
      final client = await ssh();
      try {
        await sshExec(client, moshKillCommand(pid, id), timeout);
      } finally {
        client.close();
      }
    }

    try {
      final address =
          peer ?? (await InternetAddress.lookup(host.address)).first;
      final heard = _Heard();
      final udp = await MoshSession.connect(
        server: MoshServerConfig(
          host: host.address,
          port: started.port,
          key: started.key,
        ),
        cipher: ServerOnlyCipher(
          MoshPacketCipher.aesOcb(started.key),
          onPacket: () => heard.last = heard.since.elapsed,
        ),
        address: address,
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );
      return MoshShellSession._(udp, terminal, heard, kill).._attach();
    } catch (_) {
      unawaited(kill().catchError((Object _) {}));
      rethrow;
    }
  }

  @override
  Future<ShellEnd> get done => _ended.future;

  void _attach() {
    // One decoder for the stream: a UTF-8 character can span two packets.
    _output = _udp.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(terminal.write);
    terminal.onOutput = _onOutput;
    terminal.onResize = _onResize;
    // The view can change size while the session starts.
    _udp.resize(terminal.viewWidth, terminal.viewHeight);
    // The server shuts the session down when the shell exits.
    unawaited(_udp.done.then((_) => _end(killServer: false)));
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _updateLink());
  }

  void _onOutput(String data) {
    if (_ended.isCompleted) return;
    _udp.send(utf8.encode(data));
  }

  void _onResize(int width, int height, int pixelWidth, int pixelHeight) {
    if (_ended.isCompleted) return;
    _udp.resize(width, height);
  }

  void _updateLink() {
    final since = _heard.since;
    link.value = (
      link: switch (_heard.last) {
        null when since.elapsed < silentAfter => MoshLink.connecting,
        null => MoshLink.silent,
        final last when since.elapsed - last < staleAfter => MoshLink.live,
        _ => MoshLink.stale,
      },
      rtt: _udp.smoothedRtt,
    );
  }

  /// mosh keeps its own link state; nothing to stop while the app is away.
  @override
  void appPaused() {}

  /// Sends from a new local socket, for a network that changed while the
  /// app was away. The session goes on.
  @override
  Future<void> appResumed() async {
    if (_ended.isCompleted) return;
    try {
      await _udp.rehome();
    } catch (e) {
      debugPrint('shellherd: mosh rehome failed: $e');
    }
  }

  void _end({required bool killServer}) {
    if (_ended.isCompleted) return;
    _tick.cancel();
    unawaited(_output.cancel());
    // A new session can own the terminal by now; leave its callbacks.
    if (terminal.onOutput == _onOutput) terminal.onOutput = null;
    if (terminal.onResize == _onResize) terminal.onResize = null;
    unawaited(_udp.close());
    if (killServer) {
      unawaited(
        _killServer().catchError(
          (Object e) => debugPrint('shellherd: cannot end mosh-server: $e'),
        ),
      );
    }
    _ended.complete((exitCode: null, lost: false));
  }

  /// Ends the session: the app closes its side, and ends mosh-server over
  /// a new SSH connection, as mosh has no message for that.
  @override
  void close() => _end(killServer: true);
}

/// When the last packet came from the server, on [since].
class _Heard {
  final since = Stopwatch()..start();
  Duration? last;
}

/// Takes only packets that the server sent: mosh marks their nonce with the
/// high bit. dart_mosh does not check it, so a packet of the app sent back
/// to it would decrypt too. [onPacket] runs for each packet that decrypts.
class ServerOnlyCipher implements MoshCipher {
  ServerOnlyCipher(this._inner, {required this.onPacket});

  final MoshCipher _inner;
  final void Function() onPacket;

  @override
  Uint8List encrypt({required int nonce, required Uint8List plaintext}) =>
      _inner.encrypt(nonce: nonce, plaintext: plaintext);

  @override
  Uint8List decrypt(Uint8List packet) {
    if (packet.isEmpty || packet[0] & 0x80 == 0) {
      throw const MoshException('not a packet from mosh-server');
    }
    final plain = _inner.decrypt(packet);
    onPacket();
    return plain;
  }
}
