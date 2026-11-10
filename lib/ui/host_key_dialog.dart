import 'package:flutter/material.dart';

import '../ssh/host.dart';
import '../ssh/known_hosts.dart';

/// Asks whether to trust [key], the first key that [host] showed. A
/// [TrustPrompt] for [SshConnector] calls it.
Future<bool> showHostKeyDialog(
  BuildContext context,
  Host host,
  HostKey key,
) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('New host: ${host.label}'),
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
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Trust'),
          ),
        ],
      ),
    ) ??
    false;
