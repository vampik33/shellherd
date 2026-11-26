import 'package:flutter/material.dart';

import 'palette.dart';

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
