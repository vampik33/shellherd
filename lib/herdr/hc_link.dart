import 'package:dartssh2/dartssh2.dart';

import 'api/hc_client.dart';
import 'herdr_link.dart';

/// Finds the herdr-core socket of [session] (the default session if null)
/// on the remote host and says hello. [socketPath] skips the lookup.
///
/// It only dials the socket: `hc connect` would start a core when none
/// runs, and a core started over SSH lacks the desktop session.
///
/// Throws as [HerdrLink.connect] does; a missing socket is a
/// [HerdrNoSocketException]. Without [socketPath], throws [ArgumentError]
/// when [session] cannot be an hc session name.
Future<HcClient> connectHc(
  SSHClient ssh, {
  String? session,
  String? socketPath,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final path =
      socketPath ??
      await remoteValue(
        ssh,
        hcSocketBase,
        (base) => hcSocketPath(base, hcSessionName(session)),
        what: 'socket dir lookup',
        timeout: timeout,
      );
  return withSocketPath(
    path,
    () => HcClient.connect(sshDialer(ssh, path), timeout: timeout),
  );
}

/// Where herdr-core puts its sockets, as hc decides it on Linux and macOS
/// when neither `HC_SOCKET` nor `socket` in its config sets the path:
/// `run <dir>` for a non-empty `$XDG_RUNTIME_DIR`, else for
/// `/run/user/<uid>` if it exists; else `state <dir>` for the state home.
const hcSocketBase =
    r'$(if [ -n "$XDG_RUNTIME_DIR" ]; then printf "run %s" "$XDG_RUNTIME_DIR"; '
    r'elif [ -d "/run/user/$(id -u)" ]; then printf "run /run/user/%s" "$(id -u)"; '
    r'else printf "state %s" "${XDG_STATE_HOME:-$HOME/.local/state}"; fi)';

/// The socket of hc session [name] from what [hcSocketBase] gave:
/// `<run>/herdr-core/<name>.sock`, or
/// `<state>/herdr-core/<name>/<name>.sock`. Null for anything else.
String? hcSocketPath(String base, String name) {
  const run = 'run ', state = 'state ';
  if (base.startsWith('$run/')) {
    return '${base.substring(run.length)}/herdr-core/$name.sock';
  }
  if (base.startsWith('$state/')) {
    return '${base.substring(state.length)}/herdr-core/$name/$name.sock';
  }
  return null;
}

/// The hc session name that [session] stands for, by the rules of hc:
/// spaces around it dropped, empty or null for `default`, and no name that
/// cannot be a folder name. Throws [ArgumentError] for such a name.
String hcSessionName(String? session) {
  final name = session?.trim() ?? '';
  if (name.isEmpty) return 'default';
  if (name == '.' ||
      name == '..' ||
      name.runes.any((c) => c < 0x20 || (c >= 0x7f && c < 0xa0)) ||
      name.contains(RegExp(r'[/\\:*?"<>|]'))) {
    throw ArgumentError.value(session, 'session', 'not an hc session name');
  }
  return name;
}
