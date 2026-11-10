import 'dart:async';

import '../herdr/api/herdr_client.dart';
import '../herdr/herdr_connection.dart';
import '../ssh/host.dart';
import 'notifier.dart';

/// The statuses that notify: the agent needs the user, or it finished.
const alertStatuses = {AgentStatus.blocked, AgentStatus.done};

/// What a notification says about one agent.
class AgentAlert {
  const AgentAlert({
    required this.paneId,
    required this.status,
    required this.agent,
    required this.where,
  });

  final String paneId;

  /// One of [alertStatuses].
  final AgentStatus status;

  /// The name of the agent, for example "claude".
  final String agent;

  /// Workspace and tab, for example "api-server › 1".
  final String where;
}

/// The notifications to show and to take back, from the statuses [before]
/// (pane id to status) to [now].
///
/// An agent alerts when its status changes into one of [alertStatuses]. Its
/// notification goes when it leaves them, or the agent goes away.
({List<AgentAlert> show, List<String> cancel}) agentChanges(
  Map<String, AgentStatus> before,
  HerdrSnapshot now,
) {
  final show = <AgentAlert>[];
  final current = <String>{};
  for (final agent in now.agents) {
    if (!alertStatuses.contains(agent.status)) continue;
    current.add(agent.paneId);
    if (before[agent.paneId] == agent.status) continue;
    show.add(
      AgentAlert(
        paneId: agent.paneId,
        status: agent.status,
        agent: agent.displayName,
        where: _where(now, agent),
      ),
    );
  }
  final cancel = [
    for (final MapEntry(key: paneId, value: status) in before.entries)
      if (alertStatuses.contains(status) && !current.contains(paneId)) paneId,
  ];
  return (show: show, cancel: cancel);
}

String _where(HerdrSnapshot s, Agent agent) {
  final workspace = s.workspace(agent.workspaceId)?.label;
  final tab = s.tab(agent.tabId)?.label;
  return [?workspace, ?tab].join(' › ');
}

/// Watches the agents of one host over [connection], which it owns, and
/// notifies when one needs the user or is done.
///
/// The first snapshot only sets the statuses to compare with: turning the
/// watch on does not notify about what is already on the screen. The
/// statuses stay over a lost link, so a change during the gap notifies once
/// the link is back, and nothing notifies twice.
class AgentWatcher {
  AgentWatcher(
    this.host,
    this.connection, {
    required this.notifier,
    this.noServerRetry = const Duration(minutes: 1),
  });

  final Host host;
  final HerdrConnection connection;
  final Notifier notifier;

  /// How often to look again for a herdr server that was not running.
  /// [HerdrConnection] does not retry that by itself.
  final Duration noServerRetry;

  Map<String, AgentStatus>? _last;
  String? _shown;
  Timer? _retry;

  void start() {
    connection.snapshot.addListener(_onSnapshot);
    connection.state.addListener(_onState);
    connection.connect();
  }

  /// The pane that the user has on the screen, or null. It does not notify,
  /// and its notification goes.
  set shownPane(String? paneId) {
    _shown = paneId;
    if (paneId != null) unawaited(notifier.cancel(host.id, paneId));
  }

  void _onSnapshot() {
    final snapshot = connection.snapshot.value;
    if (snapshot == null) return;
    final before = _last;
    _last = {for (final a in snapshot.agents) a.paneId: a.status};
    if (before == null) return;
    final changes = agentChanges(before, snapshot);
    for (final paneId in changes.cancel) {
      unawaited(notifier.cancel(host.id, paneId));
    }
    for (final alert in changes.show) {
      if (alert.paneId != _shown) unawaited(notifier.show(host, alert));
    }
  }

  void _onState() {
    _retry?.cancel();
    _retry = null;
    if (connection.state.value is LinkNoServer) {
      _retry = Timer(noServerRetry, connection.connect);
    }
  }

  void dispose() {
    _retry?.cancel();
    connection.snapshot.removeListener(_onSnapshot);
    connection.state.removeListener(_onState);
    connection.dispose();
  }
}
