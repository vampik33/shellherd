import 'package:flutter/material.dart';

import '../ssh/host.dart';
import '../ssh/ssh_connector.dart';
import 'palette.dart';

/// A strip above the content that says what went wrong.
class StatusBanner extends StatelessWidget {
  const StatusBanner(this.message, {super.key, this.detail, this.action});

  final String message;
  final String? detail;
  final (String, VoidCallback)? action;

  /// About six lines of the detail.
  static const maxDetailHeight = 100.0;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message,
                    style: TextStyle(color: scheme.onErrorContainer),
                  ),
                  // A long detail scrolls, so the banner leaves room for
                  // the screen under it.
                  if (detail case final detail?)
                    ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxHeight: maxDetailHeight,
                      ),
                      child: SingleChildScrollView(
                        primary: false,
                        child: SelectableText(
                          detail,
                          style: TextStyle(
                            fontFamily: monoFont,
                            fontSize: 12,
                            color: scheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (action case (final label, final onPressed))
              TextButton(onPressed: onPressed, child: Text(label)),
          ],
        ),
      ),
    );
  }
}

/// What a failed SSH connection shows. A changed key gets no way forward
/// here: the user forgets the old key on purpose.
StatusBanner sshFailureBanner(
  SshConnectException error,
  (String, VoidCallback) retry,
) {
  final host = error.host;
  return switch (error) {
    SshHostKeyChanged(:final trusted, :final presented) => StatusBanner(
      'The host key of ${host.address} changed.',
      detail:
          'Trusted: $trusted\nServer:  $presented\n'
          'If you expected this, edit the host and forget the old key.',
    ),
    SshHostKeyRejected() => StatusBanner(
      'The host key was not trusted.',
      action: retry,
    ),
    SshAuthFailed() => StatusBanner(
      'The server refused the ${switch (host.auth) {
        SshAuth.key => 'key',
        SshAuth.password => 'password',
        SshAuth.tailscale => 'Tailscale login',
      }} for ${host.user}@${host.address}.',
      action: retry,
    ),
    SshSecretsUnreadable(:final cause) => StatusBanner(
      'The phone could not read the saved ${switch (host.auth) {
        SshAuth.password => 'password',
        SshAuth.key || SshAuth.tailscale => 'key',
      }} for ${host.label}.',
      detail: 'Nothing was deleted.\n${cause.cause}',
      action: retry,
    ),
    SshTailscaleCheckNeeded(:final url) => StatusBanner(
      'Tailscale wants you to approve this login in a browser.',
      detail: '$url',
      action: retry,
    ),
    SshNetworkException(:final cause) => StatusBanner(
      'Cannot reach ${host.address}:${host.port}.',
      detail: '$cause',
      action: retry,
    ),
  };
}

/// Calls [onDisconnect], then closes the screens of a host, and with them
/// their connections, back to the host list.
IconButton disconnectButton(
  BuildContext context, {
  VoidCallback? onDisconnect,
}) => IconButton(
  tooltip: 'Disconnect',
  icon: const Icon(Icons.link_off),
  onPressed: () {
    onDisconnect?.call();
    // pop, not maybePop: a herdr screen with a pane open holds back.
    Navigator.of(context).popUntil((route) => route.isFirst);
  },
);

/// The end of a top bar: the link [chip] and [disconnectButton].
List<Widget> linkActions(
  BuildContext context,
  Widget chip, {
  VoidCallback? onDisconnect,
}) => [
  chip,
  disconnectButton(context, onDisconnect: onDisconnect),
  const SizedBox(width: 8),
];

/// The state of a link, for the top bar.
class LinkChip extends StatelessWidget {
  const LinkChip(this.label, this.color, {super.key});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Chip(
    label: Text(label),
    avatar: Icon(Icons.circle, size: 10, color: color),
    visualDensity: VisualDensity.compact,
  );
}
