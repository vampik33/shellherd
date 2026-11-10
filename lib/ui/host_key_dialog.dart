import 'package:flutter/material.dart';

import '../ssh/host.dart';
import '../ssh/known_hosts.dart';
import 'confirm_dialog.dart';

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
            style: const TextStyle(fontFamily: 'monospace'),
          ),
          const SizedBox(height: 12),
          const Text(
            'On the server, ssh-keygen -lf '
            '/etc/ssh/ssh_host_ed25519_key.pub shows it.',
          ),
        ],
      ),
    );
