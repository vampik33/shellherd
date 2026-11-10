import 'package:flutter/material.dart';

/// Asks with Cancel and [action] buttons. True only for [action]; closing
/// the dialog any other way is a no.
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required Widget content,
  required String action,
  bool barrierDismissible = true,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: content,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
