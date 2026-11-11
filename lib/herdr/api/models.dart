/// Typed views of the herdr socket API (protocol 22) used by shellherd.
///
/// Parsers keep only the fields the app uses and ignore unknown fields, as
/// the herdr docs ask of JSON API clients. A missing required field or a
/// wrong type raises [HerdrProtocolException].
library;

import 'herdr_errors.dart';
import 'json_fields.dart';

enum AgentStatus {
  idle,
  working,
  blocked,
  done,
  unknown;

  /// Maps a wire value; a value this build does not know maps to [unknown].
  static AgentStatus fromWire(Object? value) {
    for (final s in values) {
      if (s.name == value) return s;
    }
    return unknown;
  }
}

enum ReadSource {
  visible('visible'),
  recent('recent'),
  recentUnwrapped('recent_unwrapped'),
  detection('detection');

  const ReadSource(this.wire);
  final String wire;

  static ReadSource fromWire(Object? value) => values.firstWhere(
    (s) => s.wire == value,
    orElse: () => throw HerdrProtocolException('unknown read source: $value'),
  );
}

enum ReadFormat {
  text,
  ansi;

  static ReadFormat fromWire(Object? value) => values.firstWhere(
    (f) => f.name == value,
    orElse: () => throw HerdrProtocolException('unknown read format: $value'),
  );
}

class HerdrPing {
  const HerdrPing({
    required this.version,
    required this.protocol,
    required this.capabilities,
  });

  factory HerdrPing.fromJson(Map<String, Object?> j) => HerdrPing(
    version: jsonField<String>(j, 'version'),
    protocol: jsonField<int>(j, 'protocol'),
    capabilities: jsonOptional<Map<String, Object?>>(j, 'capabilities') ?? const {},
  );

  final String version;
  final int protocol;
  final Map<String, Object?> capabilities;
}

class Workspace {
  const Workspace({
    required this.id,
    required this.number,
    required this.label,
    required this.focused,
    required this.paneCount,
    required this.tabCount,
    required this.activeTabId,
    required this.status,
  });

  factory Workspace.fromJson(Map<String, Object?> j) => Workspace(
    id: jsonField<String>(j, 'workspace_id'),
    number: jsonField<int>(j, 'number'),
    label: jsonField<String>(j, 'label'),
    focused: jsonField<bool>(j, 'focused'),
    paneCount: jsonField<int>(j, 'pane_count'),
    tabCount: jsonField<int>(j, 'tab_count'),
    activeTabId: jsonField<String>(j, 'active_tab_id'),
    status: AgentStatus.fromWire(j['agent_status']),
  );

  final String id;
  final int number;
  final String label;
  final bool focused;
  final int paneCount;
  final int tabCount;
  final String activeTabId;
  final AgentStatus status;
}

class Tab {
  const Tab({
    required this.id,
    required this.workspaceId,
    required this.number,
    required this.label,
    required this.focused,
    required this.paneCount,
    required this.status,
  });

  factory Tab.fromJson(Map<String, Object?> j) => Tab(
    id: jsonField<String>(j, 'tab_id'),
    workspaceId: jsonField<String>(j, 'workspace_id'),
    number: jsonField<int>(j, 'number'),
    label: jsonField<String>(j, 'label'),
    focused: jsonField<bool>(j, 'focused'),
    paneCount: jsonField<int>(j, 'pane_count'),
    status: AgentStatus.fromWire(j['agent_status']),
  );

  final String id;
  final String workspaceId;
  final int number;
  final String label;
  final bool focused;
  final int paneCount;
  final AgentStatus status;
}

class Pane {
  const Pane({
    required this.id,
    required this.workspaceId,
    required this.tabId,
    required this.focused,
    required this.status,
    required this.revision,
    this.agent,
    this.displayAgent,
    this.title,
    this.label,
    this.cwd,
    this.terminalTitle,
    this.turn,
  });

  factory Pane.fromJson(Map<String, Object?> j) => Pane(
    id: jsonField<String>(j, 'pane_id'),
    workspaceId: jsonField<String>(j, 'workspace_id'),
    tabId: jsonField<String>(j, 'tab_id'),
    focused: jsonField<bool>(j, 'focused'),
    status: AgentStatus.fromWire(j['agent_status']),
    revision: jsonField<int>(j, 'revision'),
    agent: jsonOptional<String>(j, 'agent'),
    displayAgent: jsonOptional<String>(j, 'display_agent'),
    title: jsonOptional<String>(j, 'title'),
    label: jsonOptional<String>(j, 'label'),
    cwd: jsonOptional<String>(j, 'cwd'),
    terminalTitle: jsonOptional<String>(j, 'terminal_title_stripped'),
  );

  /// Public pane id such as `w1:p2`.
  final String id;
  final String workspaceId;
  final String tabId;
  final bool focused;
  final AgentStatus status;
  final int revision;

  /// Canonical agent kind (`claude`, `codex`), or null without an agent.
  final String? agent;
  final String? displayAgent;
  final String? title;
  final String? label;
  final String? cwd;
  final String? terminalTitle;

  /// Goes up each time the agent stops working. Only the Herdr app counts
  /// turns; null for herdr.
  final int? turn;

  /// The best name there is for this pane.
  String get displayName =>
      label ?? title ?? displayAgent ?? agent ?? terminalTitle ?? id;
}

class Agent {
  const Agent({
    required this.paneId,
    required this.workspaceId,
    required this.tabId,
    required this.status,
    this.name,
    this.agent,
    this.displayAgent,
    this.title,
  });

  factory Agent.fromJson(Map<String, Object?> j) => Agent(
    paneId: jsonField<String>(j, 'pane_id'),
    workspaceId: jsonField<String>(j, 'workspace_id'),
    tabId: jsonField<String>(j, 'tab_id'),
    status: AgentStatus.fromWire(j['agent_status']),
    name: jsonOptional<String>(j, 'name'),
    agent: jsonOptional<String>(j, 'agent'),
    displayAgent: jsonOptional<String>(j, 'display_agent'),
    title: jsonOptional<String>(j, 'title'),
  );

  final String paneId;
  final String workspaceId;
  final String tabId;
  final AgentStatus status;

  /// Unique live agent name, if one was given.
  final String? name;
  final String? agent;
  final String? displayAgent;
  final String? title;

  /// The best name there is for this agent.
  String get displayName => name ?? displayAgent ?? agent ?? 'agent';
}

class HerdrSnapshot {
  const HerdrSnapshot({
    required this.version,
    required this.protocol,
    required this.workspaces,
    required this.tabs,
    required this.panes,
    required this.agents,
    this.focusedWorkspaceId,
    this.focusedTabId,
    this.focusedPaneId,
  });

  factory HerdrSnapshot.fromJson(Map<String, Object?> j) => HerdrSnapshot(
    version: jsonField<String>(j, 'version'),
    protocol: jsonField<int>(j, 'protocol'),
    focusedWorkspaceId: jsonOptional<String>(j, 'focused_workspace_id'),
    focusedTabId: jsonOptional<String>(j, 'focused_tab_id'),
    focusedPaneId: jsonOptional<String>(j, 'focused_pane_id'),
    workspaces: jsonList(j, 'workspaces', Workspace.fromJson),
    tabs: jsonList(j, 'tabs', Tab.fromJson),
    panes: jsonList(j, 'panes', Pane.fromJson),
    agents: jsonList(j, 'agents', Agent.fromJson),
  );

  final String version;
  final int protocol;
  final String? focusedWorkspaceId;
  final String? focusedTabId;
  final String? focusedPaneId;
  final List<Workspace> workspaces;
  final List<Tab> tabs;
  final List<Pane> panes;
  final List<Agent> agents;

  Pane? pane(String id) => panes.where((p) => p.id == id).firstOrNull;

  Workspace? workspace(String id) =>
      workspaces.where((w) => w.id == id).firstOrNull;

  Tab? tab(String id) => tabs.where((t) => t.id == id).firstOrNull;
}

class PaneRead {
  const PaneRead({
    required this.paneId,
    required this.workspaceId,
    required this.tabId,
    required this.source,
    required this.format,
    required this.text,
    required this.revision,
    required this.truncated,
  });

  factory PaneRead.fromJson(Map<String, Object?> j) => PaneRead(
    paneId: jsonField<String>(j, 'pane_id'),
    workspaceId: jsonField<String>(j, 'workspace_id'),
    tabId: jsonField<String>(j, 'tab_id'),
    source: ReadSource.fromWire(j['source']),
    format: ReadFormat.fromWire(j['format']),
    text: jsonField<String>(j, 'text'),
    revision: jsonField<int>(j, 'revision'),
    truncated: jsonField<bool>(j, 'truncated'),
  );

  final String paneId;
  final String workspaceId;
  final String tabId;
  final ReadSource source;
  final ReadFormat format;
  final String text;
  final int revision;
  final bool truncated;
}

/// One event filter for `events.subscribe`.
class Subscription {
  /// A lifecycle event such as `workspace.created` or `pane.closed`.
  const Subscription.lifecycle(this.type) : paneId = null;

  /// Status changes of one pane. herdr requires the pane id, and rejects the
  /// whole subscribe request if the pane does not exist.
  const Subscription.agentStatus(String this.paneId)
    : type = 'pane.agent_status_changed';

  final String type;
  final String? paneId;

  Map<String, Object?> toJson() => {
    'type': type,
    if (paneId != null) 'pane_id': paneId,
  };
}

/// One pushed line on a subscription connection:
/// `{"event": "workspace_created", "data": {"type": "workspace_created", ...}}`.
class HerdrEvent {
  const HerdrEvent(this.kind, this.data);

  factory HerdrEvent.fromJson(Map<String, Object?> j) =>
      HerdrEvent(jsonField<String>(j, 'event'), jsonField<Map<String, Object?>>(j, 'data'));

  /// Wire kind with underscores, for example `pane_agent_status_changed`.
  final String kind;
  final Map<String, Object?> data;

  String? get paneId => _idOf('pane');

  String? get workspaceId => _idOf('workspace');

  /// `<kind>_id` on the event itself, or inside its nested `<kind>` record.
  String? _idOf(String kind) =>
      jsonOptional<String>(data, '${kind}_id') ??
      jsonOptional<String>(jsonOptional<Map<String, Object?>>(data, kind) ?? const {}, '${kind}_id');

  /// Present on `pane_agent_status_changed`.
  AgentStatus? get agentStatus => data.containsKey('agent_status')
      ? AgentStatus.fromWire(data['agent_status'])
      : null;
}
