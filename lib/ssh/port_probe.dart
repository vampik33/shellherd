import 'dart:io';

import '../bounded_open.dart';

/// Answers whether a host is online.
typedef HostProbe = Future<bool> Function(String address, int port);

/// Whether [address] takes a TCP connection on [port] within [timeout]: a
/// refused port, a name that does not resolve and no answer are all false.
/// The socket is closed at once; nothing is sent on it.
Future<bool> sshPortOpen(
  String address,
  int port, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  try {
    // The connect timeout may not cover the name lookup.
    final socket = await boundedOpen(
      Socket.connect(address, port, timeout: timeout),
      timeout,
      (late) => late.destroy(),
    );
    socket.destroy();
    return true;
  } catch (_) {
    return false;
  }
}
