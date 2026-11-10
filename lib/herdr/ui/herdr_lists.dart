import 'package:flutter/material.dart';

import '../../ui/palette.dart';
import '../api/herdr_client.dart';

const _mono = 'monospace';

/// The colour of an agent state, as in herdr. An unknown state is hollow.
class StatusDot extends StatelessWidget {
  const StatusDot(this.status, {super.key});

  final AgentStatus status;

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      AgentStatus.blocked => Mocha.red,
      AgentStatus.working => Mocha.yellow,
      AgentStatus.done => Mocha.green,
      AgentStatus.idle => Mocha.surface1,
      AgentStatus.unknown => null,
    };
    return Semantics(
      label: status.name,
      child: Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: color == null ? Border.all(color: Mocha.overlay) : null,
        ),
      ),
    );
  }
}

/// All agents of the session, the ones that need attention first.
class AgentsList extends StatelessWidget {
  const AgentsList(this.snapshot, {super.key});

  final HerdrSnapshot snapshot;

  static const _groups = [
    ('needs you', [AgentStatus.blocked, AgentStatus.done]),
    ('working', [AgentStatus.working]),
    ('idle', [AgentStatus.idle, AgentStatus.unknown]),
  ];

  @override
  Widget build(BuildContext context) {
    if (snapshot.agents.isEmpty) {
      return const _Empty('No agents are running.');
    }
    final workspaces = {for (final w in snapshot.workspaces) w.id: w.label};
    final tabs = {for (final t in snapshot.tabs) t.id: t.label};

    Widget row(Agent a) => _Row(
      status: a.status,
      title: a.displayName,
      aside: '${workspaces[a.workspaceId]} › ${tabs[a.tabId]}',
      detail: a.title ?? _statusLine(a.status),
      detailColor: a.status == AgentStatus.blocked ? Mocha.red : null,
    );

    List<Widget> section(String title, List<AgentStatus> statuses) {
      final agents = [
        for (final s in statuses)
          ...snapshot.agents.where((a) => a.status == s),
      ];
      return agents.isEmpty
          ? const []
          : [_Section(title, agents.length), ...agents.map(row)];
    }

    return ListView(
      key: const PageStorageKey('agents'),
      children: [
        for (final (title, statuses) in _groups) ...section(title, statuses),
      ],
    );
  }

  /// An idle agent has nothing to say.
  static String? _statusLine(AgentStatus status) => switch (status) {
    AgentStatus.idle || AgentStatus.unknown => null,
    _ => status.name,
  };
}

/// Workspaces, their tabs and their panes, as in the herdr sidebar.
class SpacesList extends StatelessWidget {
  const SpacesList(this.snapshot, {super.key});

  final HerdrSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    if (snapshot.workspaces.isEmpty) return const _Empty('No spaces yet.');
    return ListView(
      key: const PageStorageKey('spaces'),
      children: [
        _Section('spaces', snapshot.workspaces.length),
        for (final w in snapshot.workspaces) ...[
          _Row(
            status: w.status,
            title: w.label,
            aside: '${w.paneCount} pane${w.paneCount == 1 ? '' : 's'}',
          ),
          for (final t in snapshot.tabs.where(
            (t) => t.workspaceId == w.id,
          )) ...[
            _Row(status: t.status, title: t.label, indent: 1),
            for (final p in snapshot.panes.where((p) => p.tabId == t.id))
              _Row(
                status: p.status,
                title: p.displayName,
                aside: p.cwd,
                indent: 2,
              ),
          ],
        ],
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title, this.count);

  final String title;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontFamily: _mono,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Mocha.subtext,
          ),
        ),
        Text(
          '$count',
          style: const TextStyle(
            fontFamily: _mono,
            fontSize: 12,
            color: Mocha.overlay,
          ),
        ),
      ],
    ),
  );
}

/// One line with a state dot, and an optional second line under it.
class _Row extends StatelessWidget {
  const _Row({
    required this.status,
    required this.title,
    this.aside,
    this.detail,
    this.detailColor,
    this.indent = 0,
  });

  final AgentStatus status;
  final String title;
  final String? aside;
  final String? detail;
  final Color? detailColor;
  final int indent;

  static const _dim = TextStyle(
    fontFamily: _mono,
    fontSize: 12,
    color: Mocha.overlay,
  );

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(12.0 + 16 * indent, 9, 12, 9),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            StatusDot(status),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: _mono,
                  fontWeight: indent == 0 ? FontWeight.w700 : null,
                ),
              ),
            ),
            if (aside case final aside?) ...[
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  aside,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _dim,
                ),
              ),
            ],
          ],
        ),
        if (detail case final detail?)
          Padding(
            padding: const EdgeInsets.only(left: 17),
            child: Text(
              detail,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _dim.copyWith(color: detailColor),
            ),
          ),
      ],
    ),
  );
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Center(child: Text(text));
}
