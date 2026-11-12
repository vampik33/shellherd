import 'package:flutter/material.dart';

import '../ssh/host.dart';
import '../ssh/known_hosts.dart';
import 'confirm_dialog.dart';
import 'palette.dart';

/// Asks whether to trust [key], the first key that [host] showed. A
/// [TrustPrompt] for [SshConnector] calls it.
Future<bool> showHostKeyDialog(BuildContext context, Host host, HostKey key) =>
    confirmDialog(
      context,
      title: 'New host: ${host.label}',
      action: 'Trust',
      barrierDismissible: false,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This is the first connection to '
            '${host.user}@${host.address}:${host.port}. '
            'Trust it only if this key matches the server:',
          ),
          const SizedBox(height: 12),
          SelectableText(
            '${key.type}\n${key.fingerprint}',
            style: const TextStyle(fontFamily: monoFont),
          ),
          const SizedBox(height: 12),
          Text(
            'On the server, ssh-keygen -lf '
            '${hostKeyFile(key.type)} shows it.',
          ),
        ],
      ),
    );

/// Where OpenSSH keeps the public host key of [type] by default.
String hostKeyFile(String type) {
  final name = switch (type) {
    'ssh-rsa' => 'rsa',
    'ssh-ed25519' => 'ed25519',
    _ when type.startsWith('ecdsa-') => 'ecdsa',
    _ => type,
  };
  return '/etc/ssh/ssh_host_${name}_key.pub';
}
