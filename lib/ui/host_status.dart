import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'palette.dart';

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
  final connecting = Socket.connect(address, port, timeout: timeout);
  try {
    // The connect timeout may not cover the name lookup.
    (await connecting.timeout(timeout)).destroy();
    return true;
  } catch (_) {
    // A connect that comes after the timeout is closed too.
    unawaited(connecting.then((s) => s.destroy(), onError: (Object _) {}));
    return false;
  }
}

/// What the host list knows about a host's SSH port.
enum HostStatus {
  online('online', Graphite.green),
  offline('offline', Graphite.red),
  unknown('not checked yet', Graphite.dim),
  disconnected('disconnected', Graphite.dim);

  const HostStatus(this.text, this.color);
  final String text;
  final Color color;
}

/// The coloured dot before a host in the list.
class HostStatusDot extends StatelessWidget {
  const HostStatusDot(this.label, this.status, {super.key});

  final String label;
  final HostStatus status;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: '$label: ${status.text}',
    child: Icon(Icons.circle, size: 12, color: status.color),
  );
}
