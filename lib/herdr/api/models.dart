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
}

enum ReadFormat { text, ansi }

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
    required this.label,
    required this.paneCount,
    required this.status,
  });

  factory Workspace.fromJson(Map<String, Object?> j) => Workspace(
    id: jsonField<String>(j, 'workspace_id'),
    label: jsonField<String>(j, 'label'),
    paneCount: jsonField<int>(j, 'pane_count'),
    status: AgentStatus.fromWire(j['agent_status']),
  );

  final String id;
  final String label;
  final int paneCount;
  final AgentStatus status;
}

class Tab {
  const Tab({
    required this.id,
    required this.workspaceId,
    required this.label,
    required this.paneCount,
    required this.status,
  });

  factory Tab.fromJson(Map<String, Object?> j) => Tab(
    id: jsonField<String>(j, 'tab_id'),
    workspaceId: jsonField<String>(j, 'workspace_id'),
    label: jsonField<String>(j, 'label'),
    paneCount: jsonField<int>(j, 'pane_count'),
    status: AgentStatus.fromWire(j['agent_status']),
  );

  final String id;
  final String workspaceId;
  final String label;
  final int paneCount;
  final AgentStatus status;
}

class Pane {
  const Pane({
    required this.id,
    required this.workspaceId,
    required this.tabId,
    required this.status,
    this.agent,
    this.displayAgent,
    this.title,
    this.label,
    this.cwd,
    this.terminalTitle,
    this.turn,
    this.agentSession,
  });

  factory Pane.fromJson(Map<String, Object?> j) => Pane(
    id: jsonField<String>(j, 'pane_id'),
    workspaceId: jsonField<String>(j, 'workspace_id'),
    tabId: jsonField<String>(j, 'tab_id'),
    status: AgentStatus.fromWire(j['agent_status']),
    agent: jsonOptional<String>(j, 'agent'),
    displayAgent: jsonOptional<String>(j, 'display_agent'),
    title: jsonOptional<String>(j, 'title'),
    label: jsonOptional<String>(j, 'label'),
    cwd: jsonOptional<String>(j, 'cwd'),
    terminalTitle: jsonOptional<String>(j, 'terminal_title_stripped'),
    agentSession: AgentSession.tryParse(j['agent_session']),
  );

  /// Public pane id such as `w1:p2`.
  final String id;
  final String workspaceId;
  final String tabId;
  final AgentStatus status;

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

  /// The session the agent reported to herdr; null when it reported none,
  /// or for the Herdr app.
  final AgentSession? agentSession;

  /// The best name there is for this pane.
  String get displayName =>
      label ?? title ?? displayAgent ?? agent ?? terminalTitle ?? id;
}

/// The session an agent reported to herdr, by herdr's integration hook.
class AgentSession {
  const AgentSession({
    required this.agent,
    required this.kind,
    required this.value,
  });

  factory AgentSession.fromJson(Map<String, Object?> j) => AgentSession(
    agent: jsonField<String>(j, 'agent'),
    kind: AgentSessionKind.fromWire(jsonField<String>(j, 'kind')),
    value: jsonField<String>(j, 'value'),
  );

  /// The session in [json]; null when there is none or it is malformed.
  /// Only the chat view needs it, so a bad one must not fail the snapshot.
  static AgentSession? tryParse(Object? json) {
    if (json is! Map<String, Object?>) return null;
    try {
      return AgentSession.fromJson(json);
    } on HerdrProtocolException {
      return null;
    }
  }

  /// The agent kind, such as `claude`.
  final String agent;
  final AgentSessionKind kind;

  /// The session id or the path of its transcript, by [kind]. For Claude
  /// Code herdr keeps the id, even when its hook also reports the path.
  final String value;

  /// The id of a Claude Code session, when that is what this is.
  String? get claudeSession =>
      agent == 'claude' && kind == AgentSessionKind.id ? value : null;
}

enum AgentSessionKind {
  id,
  path,
  unknown;

  /// Maps a wire value; a value this build does not know maps to [unknown].
  static AgentSessionKind fromWire(String value) {
    for (final k in values) {
      if (k.name == value) return k;
    }
    return unknown;
  }
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
    this.paneSizes = const {},
  });

  factory HerdrSnapshot.fromJson(Map<String, Object?> j) => HerdrSnapshot(
    version: jsonField<String>(j, 'version'),
    protocol: jsonField<int>(j, 'protocol'),
    workspaces: jsonList(j, 'workspaces', Workspace.fromJson),
    tabs: jsonList(j, 'tabs', Tab.fromJson),
    panes: jsonList(j, 'panes', Pane.fromJson),
    agents: jsonList(j, 'agents', Agent.fromJson),
    paneSizes: {
      for (final layout in jsonList(j, 'layouts', (l) => l))
        for (final pane in jsonList(layout, 'panes', (p) => p))
          jsonField<String>(pane, 'pane_id'): PaneSize.fromJson(
            jsonField<Map<String, Object?>>(pane, 'rect'),
          ),
    },
  );

  final String version;
  final int protocol;
  final List<Workspace> workspaces;
  final List<Tab> tabs;
  final List<Pane> panes;
  final List<Agent> agents;

  /// The size of each pane in cells, from herdr's `layouts`: its rect in
  /// the tab, which is at least the size of its terminal. Empty where the
  /// server gives no layout.
  final Map<String, PaneSize> paneSizes;

  Pane? pane(String id) => panes.where((p) => p.id == id).firstOrNull;

  Workspace? workspace(String id) =>
      workspaces.where((w) => w.id == id).firstOrNull;

  Tab? tab(String id) => tabs.where((t) => t.id == id).firstOrNull;
}

/// A size in terminal cells.
class PaneSize {
  const PaneSize(this.cols, this.rows);

  factory PaneSize.fromJson(Map<String, Object?> j) =>
      PaneSize(jsonField<int>(j, 'width'), jsonField<int>(j, 'height'));

  final int cols;
  final int rows;

  @override
  bool operator ==(Object other) =>
      other is PaneSize && other.cols == cols && other.rows == rows;

  @override
  int get hashCode => Object.hash(cols, rows);

  @override
  String toString() => '${cols}x$rows';
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
}
