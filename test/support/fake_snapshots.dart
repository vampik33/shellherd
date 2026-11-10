/// Wire shapes of a herdr snapshot, for fake servers.
library;

Map<String, Object?> fakeWorkspace(
  String id,
  int number,
  String label,
  String status, {
  int panes = 1,
}) => {
  'workspace_id': id,
  'number': number,
  'label': label,
  'focused': false,
  'pane_count': panes,
  'tab_count': 1,
  'active_tab_id': '$id:t1',
  'agent_status': status,
};

Map<String, Object?> fakeTab(String workspace, String label, String status) => {
  'tab_id': '$workspace:t1',
  'workspace_id': workspace,
  'number': 1,
  'label': label,
  'focused': false,
  'pane_count': 1,
  'agent_status': status,
};

Map<String, Object?> fakePane(
  String id,
  String workspace,
  String status,
  Map<String, Object?> names,
) => {
  'pane_id': id,
  'workspace_id': workspace,
  'tab_id': '$workspace:t1',
  'focused': false,
  'agent_status': status,
  'revision': 0,
  ...names,
};

Map<String, Object?> fakeAgent(
  String pane,
  String workspace,
  String status,
  Map<String, Object?> names,
) => {
  'pane_id': pane,
  'workspace_id': workspace,
  'tab_id': '$workspace:t1',
  'agent_status': status,
  ...names,
};

Map<String, Object?> fakeSnapshot({
  List<Map<String, Object?>> workspaces = const [],
  List<Map<String, Object?>> tabs = const [],
  List<Map<String, Object?>> panes = const [],
  List<Map<String, Object?>> agents = const [],
}) => {
  'version': '0.9.5',
  'protocol': 22,
  'workspaces': workspaces,
  'tabs': tabs,
  'panes': panes,
  'agents': agents,
};
