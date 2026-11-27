import 'api/hc_client.dart';
import 'api/herdr_client.dart';
import 'transcript/claude_sessions.dart';

/// The Herdr app's session as a [HerdrSnapshot], so the lists, the pane
/// screen and the notifications serve both servers.
///
/// Spaces and tabs come from the app's [layout]; each terminal in them is a
/// pane, its address the pane id. An agent is a live terminal that reports
/// a status. A terminal outside the layout that reports one, such as an
/// agent another agent started, stands in the tab of its labels or of its
/// parent, after the tab's own panes; one with no such place is left out,
/// as the app leaves it out.
///
/// A Claude Code agent's pane has its session from [claudeSessions], by
/// the pid of the process in front of its terminal.
HerdrSnapshot hcSnapshot(
  HcHello hello,
  List<HcTerminal> terminals,
  HcLayout layout, {
  Map<int, String> claudeSessions = const {},
}) {
  Pane pane(HcTerminal t, String space, String tab) =>
      _pane(t, space, tab, claudeSessions);

  final live = {
    for (final t in terminals)
      if (t.live) t.address: t,
  };
  final inLayout = <String, (String, String)>{
    for (final space in layout.spaces)
      for (final tab in space.tabs)
        for (final address in tab.terminals) address: (space.id, tab.id),
  };
  final tabIds = {
    for (final space in layout.spaces)
      for (final tab in space.tabs) tab.id: space.id,
  };

  /// The (space, tab) of a terminal outside the layout.
  (String, String)? placeOf(HcTerminal t, [int depth = 0]) {
    final tab = t.labels[HcTerminal.tabLabel];
    final space = tabIds[tab];
    if (tab != null && space != null) return (space, tab);
    final parent = live[t.parent];
    if (parent == null || depth > 8) return null;
    return inLayout[parent.address] ?? placeOf(parent, depth + 1);
  }

  final extra = <String, List<HcTerminal>>{};
  for (final t in live.values) {
    if (inLayout.containsKey(t.address) || t.status == null) continue;
    if (placeOf(t) case (_, final tab)) (extra[tab] ??= []).add(t);
  }

  final panes = <Pane>[];
  final tabs = <Tab>[];
  final workspaces = <Workspace>[];
  for (final space in layout.spaces) {
    final spacePanes = <Pane>[];
    for (final (j, tab) in space.tabs.indexed) {
      final tabPanes = [
        for (final address in tab.terminals)
          if (live[address] case final t?) pane(t, space.id, tab.id),
        for (final t in extra[tab.id] ?? const <HcTerminal>[])
          pane(t, space.id, tab.id),
      ];
      tabs.add(
        Tab(
          id: tab.id,
          workspaceId: space.id,
          label: tab.name.isNotEmpty ? tab.name : '${j + 1}',
          paneCount: tabPanes.length,
          status: _mostUrgent(tabPanes),
        ),
      );
      spacePanes.addAll(tabPanes);
    }
    workspaces.add(
      Workspace(
        id: space.id,
        label: space.name.isNotEmpty
            ? space.name
            : _derivedName(space, spacePanes, live),
        paneCount: spacePanes.length,
        status: _mostUrgent(spacePanes),
      ),
    );
    panes.addAll(spacePanes);
  }

  return HerdrSnapshot(
    version: hello.version,
    protocol: hello.generation,
    workspaces: workspaces,
    tabs: tabs,
    panes: panes,
    agents: [
      for (final p in panes)
        if (live[p.id] case final t? when t.status != null)
          Agent(
            paneId: t.address,
            workspaceId: p.workspaceId,
            tabId: p.tabId,
            status: p.status,
            name: t.name,
            agent: t.status!.app,
            displayAgent: t.status!.app,
            title: t.status!.msg,
          ),
    ],
  );
}

Pane _pane(
  HcTerminal t,
  String space,
  String tab,
  Map<int, String> claudeSessions,
) => Pane(
  id: t.address,
  workspaceId: space,
  tabId: tab,
  status: hcAgentStatus(t),
  agent: t.status?.app,
  displayAgent: t.status?.app,
  label: t.name,
  title: t.title.isEmpty ? null : t.title,
  cwd: t.cwd,
  turn: t.turn,
  agentSession: switch (claudeSessionOf(t, claudeSessions)) {
    final session? => AgentSession(
      agent: 'claude',
      kind: AgentSessionKind.id,
      value: session,
    ),
    null => null,
  },
);

/// The pid whose Claude Code session the pane of [t] shows: the process in
/// front of a live terminal of this machine whose agent reports as Claude
/// Code. A terminal of another machine the core connects to (`machine/t7`)
/// has its pid there, and its transcript too. A pid that is not a process
/// id has none: one such pid must not stop the lookup of the others.
int? claudePid(HcTerminal t) => switch (t.foregroundPid) {
  final pid?
      when pid > 0 &&
          t.live &&
          t.status?.app == claudeCodeApp &&
          !t.address.contains('/') =>
    pid,
  _ => null,
};

/// The Claude Code session of [t] in [claudeSessions]; null without one.
String? claudeSessionOf(HcTerminal t, Map<int, String> claudeSessions) =>
    claudeSessions[claudePid(t)];

/// The state of [t] as herdr names it.
///
/// `error` needs the user as `blocked` does. An agent that finished while
/// nobody looked is `done`, as the Herdr app shows it: its [HcTerminal.turn]
/// is past the turn the app saw last. Without the app's label, the
/// program's own word counts.
AgentStatus hcAgentStatus(HcTerminal t) {
  final status = t.status;
  if (status == null) return AgentStatus.unknown;
  final seen = t.seen;
  return switch (status.state) {
    'working' => AgentStatus.working,
    'blocked' || 'error' => AgentStatus.blocked,
    'idle' || 'done' when seen != null =>
      t.turn > seen ? AgentStatus.done : AgentStatus.idle,
    'done' => AgentStatus.done,
    'idle' => AgentStatus.idle,
    _ => AgentStatus.unknown,
  };
}

/// blocked > done > working > idle, as the app sums a space or a tab up;
/// [AgentStatus.unknown] without any agent.
AgentStatus _mostUrgent(List<Pane> panes) {
  for (final s in const [
    AgentStatus.blocked,
    AgentStatus.done,
    AgentStatus.working,
    AgentStatus.idle,
  ]) {
    if (panes.any((p) => p.status == s)) return s;
  }
  return AgentStatus.unknown;
}

/// A space nobody named: the app's name for the place of its first
/// terminal ("space / tab"), else the last part of that terminal's folder,
/// else of the folder the space was made in.
String _derivedName(
  HcSpace space,
  List<Pane> panes,
  Map<String, HcTerminal> live,
) {
  final first = live[panes.firstOrNull?.id];
  final where = first?.labels[HcTerminal.whereLabel];
  if (where != null && where.contains(' / ')) {
    return where.substring(0, where.indexOf(' / '));
  }
  final folder = first?.cwd ?? space.folder;
  return folder.split('/').where((p) => p.isNotEmpty).lastOrNull ?? folder;
}
