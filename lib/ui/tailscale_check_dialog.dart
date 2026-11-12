import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ssh/ssh_connector.dart';
import 'palette.dart';

/// Shows [check] until its login ends: it closes by itself once the user
/// has approved the login in the browser. A [TailscaleCheckPrompt] for
/// [SshConnector] calls it.
void showTailscaleCheck(BuildContext context, TailscaleCheck check) =>
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => TailscaleCheckDialog(check),
      ),
    );

class TailscaleCheckDialog extends StatefulWidget {
  const TailscaleCheckDialog(this.check, {super.key});

  final TailscaleCheck check;

  @override
  State<TailscaleCheckDialog> createState() => _TailscaleCheckDialogState();
}

class _TailscaleCheckDialogState extends State<TailscaleCheckDialog> {
  String? _error;

  /// The login has ended; closing the dialog then must not cancel it.
  var _ended = false;

  @override
  void initState() {
    super.initState();
    widget.check.result.then((_) {
      _ended = true;
      if (!mounted) return;
      // This dialog only, whatever is above it by then.
      final route = ModalRoute.of(context);
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }

  /// Back closes the dialog too, which barrierDismissible does not stop:
  /// with the link gone, the login gives up rather than wait unseen.
  @override
  void dispose() {
    if (!_ended) widget.check.cancel();
    super.dispose();
  }

  Future<void> _open() async {
    var opened = false;
    try {
      opened = await launchUrl(
        widget.check.url,
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      debugPrint('shellherd: cannot open the Tailscale check: $e');
    }
    if (mounted) {
      setState(() => _error = opened ? null : 'No browser opened the link.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final host = widget.check.host;
    return AlertDialog(
      title: Text('Tailscale check: ${host.label}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tailscale SSH on ${host.address} wants you to approve this '
              'login in a browser. The login goes on by itself once you '
              'have.',
            ),
            const SizedBox(height: 12),
            SelectableText(
              '${widget.check.url}',
              style: const TextStyle(fontFamily: monoFont, fontSize: 12),
            ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: widget.check.cancel, child: const Text('Cancel')),
        FilledButton(onPressed: _open, child: const Text('Open in browser')),
      ],
    );
  }
}
