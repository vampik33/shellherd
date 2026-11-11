import 'api/hc_client.dart';
import 'api/herdr_client.dart';

/// The Herdr app's session as a [HerdrSnapshot], so the lists, the pane
/// screen and the notifications serve both servers.
///
/// Spaces and tabs come from the app's [layout]; each terminal in them is a
/// pane, its address the pane id. An agent is a live terminal that reports
/// a status. A terminal outside the layout that reports one, such as an
/// agent another agent started, stands in the tab of its labels or of its
/// parent, after the tab's own panes; one with no such place is left out,
/// as the app leaves it out. herdr-core keeps no focus: nothing is focused.
HerdrSnapshot hcSnapshot(
  HcHello hello,
  List<HcTerminal> terminals,
  HcLayout layout,
) {
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
  for (final (i, space) in layout.spaces.indexed) {
    final spacePanes = <Pane>[];
    for (final (j, tab) in space.tabs.indexed) {
      final tabPanes = [
        for (final address in tab.terminals)
          if (live[address] case final t?) _pane(t, space.id, tab.id),
        for (final t in extra[tab.id] ?? const <HcTerminal>[])
          _pane(t, space.id, tab.id),
      ];
      tabs.add(
        Tab(
          id: tab.id,
          workspaceId: space.id,
          number: j + 1,
          label: tab.name.isNotEmpty ? tab.name : '${j + 1}',
          focused: false,
          paneCount: tabPanes.length,
          status: _mostUrgent(tabPanes),
        ),
      );
      spacePanes.addAll(tabPanes);
    }
    workspaces.add(
      Workspace(
        id: space.id,
        number: i + 1,
        label: space.name.isNotEmpty
            ? space.name
            : _derivedName(space, spacePanes, live),
        focused: false,
        paneCount: spacePanes.length,
        tabCount: space.tabs.length,
        activeTabId: space.tabs.firstOrNull?.id ?? '',
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

Pane _pane(HcTerminal t, String space, String tab) => Pane(
  id: t.address,
  workspaceId: space,
  tabId: tab,
  focused: false,
  status: hcAgentStatus(t),
  revision: 0,
  agent: t.status?.app,
  displayAgent: t.status?.app,
  label: t.name,
  title: t.title.isEmpty ? null : t.title,
  cwd: t.cwd,
);

/// The state of [t] as herdr names it.
///
/// `error` needs the user as `blocked` does. An agent that finished while
/// nobody looked is `done`, as the Herdr app shows it: its [HcTerminal.turn]
/// is past the turn the app saw last. Without the app's label, the
/// program's own word counts.
AgentStatus hcAgentStatus(HcTerminal t) {
  final status = t.status;
  if (status == null) return AgentStatus.unknown;
  final seen = int.tryParse(t.labels[HcTerminal.seenLabel] ?? '');
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
