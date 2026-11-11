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
/// [HerdrNoSocketException].
Future<HcClient> connectHc(
  SSHClient ssh, {
  String? session,
  String? socketPath,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final path =
      socketPath ??
      hcSocketPath(
        await remoteDir(
          ssh,
          r'${XDG_RUNTIME_DIR:-/run/user/$(id -u)}',
          what: 'runtime dir lookup',
          timeout: timeout,
        ),
        session: session,
      );
  return withSocketPath(
    path,
    () => HcClient.connect(sshDialer(ssh, path), timeout: timeout),
  );
}

/// Path of the herdr-core socket under the remote [runtimeDir]:
/// `herdr-core/<session>.sock`.
String hcSocketPath(String runtimeDir, {String? session}) {
  final name = session ?? 'default';
  if (name.isEmpty || name.contains('/') || name.startsWith('.')) {
    throw ArgumentError.value(session, 'session', 'not an hc session name');
  }
  return '$runtimeDir/herdr-core/$name.sock';
}
