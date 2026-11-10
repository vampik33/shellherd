import 'package:shellherd/notify/agent_watcher.dart';
import 'package:shellherd/notify/notifier.dart';
import 'package:shellherd/ssh/host.dart';

/// A [Notifier] that keeps what it was asked to do.
class RecordingNotifier implements Notifier {
  final shown = <(Host, AgentAlert)>[];
  final cancelled = <(String, String)>[];

  @override
  Future<void> show(Host host, AgentAlert alert) async =>
      shown.add((host, alert));

  @override
  Future<void> cancel(String hostId, String paneId) async =>
      cancelled.add((hostId, paneId));
}
