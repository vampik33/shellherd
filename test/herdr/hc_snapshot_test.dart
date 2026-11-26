import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/hc_client.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/hc_snapshot.dart';

import '../support/fake_hc.dart';

const _hello = HcHello(version: '0.1.20', generation: 1);

HerdrSnapshot _snapshot(
  List<Map<String, Object?>> terminals,
  List<Map<String, Object?>> spaces,
) => hcSnapshot(_hello, [
  for (final t in terminals) HcTerminal.fromJson(t),
], HcLayout.fromJson({'spaces': spaces}));

Map<String, Object?> _status(String state, {String? msg}) => {
  'state': state,
  'app': 'claude-code',
  'msg': ?msg,
};

AgentStatus _of(Map<String, Object?> terminal) =>
    hcAgentStatus(HcTerminal.fromJson(terminal));

void main() {
  group('hcSnapshot', () {
    test('spaces, tabs and panes follow the layout', () {
      final s = _snapshot(
        [
          hcTerminal('t1', name: 'build'),
          hcTerminal('t2', title: 'vim notes'),
          hcTerminal('t3'),
        ],
        [
          hcSpace('s1', [
            hcTab('b1', ['t2', 't1'], name: 'fix login'),
            hcTab('b2', ['t3']),
          ], name: 'web'),
        ],
      );
      expect(s.version, '0.1.20');
      expect(s.protocol, 1);
      final w = s.workspaces.single;
      expect((w.id, w.label, w.paneCount), ('s1', 'web', 3));
      expect(s.tabs.map((t) => (t.id, t.label, t.paneCount)), [
        ('b1', 'fix login', 2),
        // An unnamed tab is called by its place.
        ('b2', '2', 1),
      ]);
      expect(s.panes.map((p) => (p.id, p.tabId, p.displayName)), [
        ('t2', 'b1', 'vim notes'),
        ('t1', 'b1', 'build'),
        ('t3', 'b2', 't3'),
      ]);
      expect(s.panes.first.cwd, '/home/u/work');
      expect(s.agents, isEmpty);
    });

    test('a terminal that is gone or finished has no pane', () {
      final s = _snapshot(
        [hcTerminal('t1'), hcTerminal('t2', state: 'finished')],
        [
          hcSpace('s1', [
            hcTab('b1', ['t1', 't2', 't9']),
          ]),
        ],
      );
      expect(s.panes.map((p) => p.id), ['t1']);
      expect(s.tabs.single.paneCount, 1);
    });

    test('an unnamed space takes the app name of its place', () {
      final s = _snapshot(
        [
          hcTerminal('t1', labels: {'where': 'shop / Fix checkout'}),
          hcTerminal('t2', cwd: '/home/u/notes'),
        ],
        [
          hcSpace('s1', [
            hcTab('b1', ['t1']),
          ]),
          hcSpace('s2', [
            hcTab('b2', ['t2']),
          ]),
          hcSpace('s3', [hcTab('b3', [])], folder: '/home/u/empty'),
        ],
      );
      expect(s.workspaces.map((w) => w.label), ['shop', 'notes', 'empty']);
    });

    test('an agent is a terminal that reports a status', () {
      final s = _snapshot(
        [
          hcTerminal(
            't1',
            name: 'review',
            status: _status('working', msg: 'reading x.rs'),
          ),
          hcTerminal('t2'),
        ],
        [
          hcSpace('s1', [
            hcTab('b1', ['t1', 't2']),
          ]),
        ],
      );
      final a = s.agents.single;
      expect((a.paneId, a.workspaceId, a.tabId), ('t1', 's1', 'b1'));
      expect(a.status, AgentStatus.working);
      expect(a.displayName, 'review');
      expect(a.title, 'reading x.rs');
      expect(s.pane('t1')!.agent, 'claude-code');
      expect(s.pane('t2')!.agent, isNull);
      expect(s.pane('t2')!.status, AgentStatus.unknown);
    });

    test('an agent outside the layout stands in the tab of its labels or '
        'of its parent', () {
      final s = _snapshot(
        [
          hcTerminal('t1', status: _status('idle')),
          hcTerminal(
            't2',
            status: _status('working'),
            labels: {'herdr.space': 's1', 'herdr.tab': 'b2'},
          ),
          hcTerminal('t3', status: _status('working'), parent: 't1'),
          hcTerminal('t4', status: _status('working'), parent: 't3'),
          // Another app's agent, and a plain helper: no place.
          hcTerminal('t5', status: _status('working')),
          hcTerminal('t6', parent: 't1'),
        ],
        [
          hcSpace('s1', [
            hcTab('b1', ['t1']),
            hcTab('b2', []),
          ]),
        ],
      );
      expect(s.panes.map((p) => (p.id, p.tabId)), [
        ('t1', 'b1'),
        ('t3', 'b1'),
        ('t4', 'b1'),
        ('t2', 'b2'),
      ]);
      expect(s.agents.map((a) => a.paneId), ['t1', 't3', 't4', 't2']);
    });

    test('a space and a tab show their most urgent agent', () {
      final s = _snapshot(
        [
          hcTerminal('t1', status: _status('working')),
          hcTerminal('t2', status: _status('blocked')),
          hcTerminal('t3', status: _status('idle')),
          hcTerminal('t4'),
        ],
        [
          hcSpace('s1', [
            hcTab('b1', ['t1', 't3']),
            hcTab('b2', ['t2']),
          ]),
          hcSpace('s2', [
            hcTab('b3', ['t4']),
          ]),
        ],
      );
      expect(s.tabs.map((t) => t.status), [
        AgentStatus.working,
        AgentStatus.blocked,
        AgentStatus.unknown,
      ]);
      expect(s.workspaces.map((w) => w.status), [
        AgentStatus.blocked,
        AgentStatus.unknown,
      ]);
    });
  });

  group('hcAgentStatus', () {
    Map<String, Object?> agent(String state, {int turn = 3, int? seen}) =>
        hcTerminal(
          't1',
          status: _status(state),
          turn: turn,
          labels: {'herdr.seen': ?seen?.toString()},
        );

    test('working and blocked are themselves; error needs the user too', () {
      expect(_of(agent('working')), AgentStatus.working);
      expect(_of(agent('blocked')), AgentStatus.blocked);
      expect(_of(agent('error')), AgentStatus.blocked);
    });

    test('a turn nobody saw in the app is done; a seen one is idle', () {
      expect(_of(agent('idle', turn: 4, seen: 3)), AgentStatus.done);
      expect(_of(agent('done', turn: 4, seen: 3)), AgentStatus.done);
      expect(_of(agent('idle', turn: 4, seen: 4)), AgentStatus.idle);
      expect(_of(agent('done', turn: 4, seen: 4)), AgentStatus.idle);
    });

    test("without the app's label the program's word counts", () {
      expect(_of(agent('done')), AgentStatus.done);
      expect(_of(agent('idle')), AgentStatus.idle);
    });

    test('no status, or a word this build does not know, is unknown', () {
      expect(_of(hcTerminal('t1')), AgentStatus.unknown);
      expect(_of(agent('pondering')), AgentStatus.unknown);
    });
  });

  group('Claude Code sessions', () {
    const id = '0d6c1f3e-1b2a-4c5d-8e9f-0a1b2c3d4e5f';
    final spaces = [
      hcSpace('s1', [
        hcTab('b1', ['t1', 't2', 't3', 't4']),
      ]),
    ];

    test('a Claude Code pane has the session of its foreground pid', () {
      final s = hcSnapshot(
        _hello,
        [
          for (final t in [
            hcTerminal('t1', status: _status('idle'), pid: 41),
            // Another agent with the same pid in the map has none.
            hcTerminal(
              't2',
              status: {'state': 'idle', 'app': 'codex'},
              pid: 42,
            ),
            // A Claude Code pane whose pid has no session.
            hcTerminal('t3', status: _status('working'), pid: 43),
            // A shell.
            hcTerminal('t4', pid: 44),
          ])
            HcTerminal.fromJson(t),
        ],
        HcLayout.fromJson({'spaces': spaces}),
        claudeSessions: {41: id, 42: id, 44: id},
      );
      final sessions = {
        for (final p in s.panes) p.id: p.agentSession?.claudeSession,
      };
      expect(sessions, {'t1': id, 't2': null, 't3': null, 't4': null});
    });

    test('a finished terminal has no foreground pid', () {
      final t = HcTerminal.fromJson({
        ...hcTerminal('t1', state: 'finished', status: _status('idle')),
        'foreground': null,
      });
      expect(t.foregroundPid, isNull);
      expect(claudePid(t), isNull);
      expect(
        claudePid(HcTerminal.fromJson(hcTerminal('t2', pid: 9))),
        isNull,
        reason: 'not an agent',
      );
      expect(
        claudePid(
          HcTerminal.fromJson(
            hcTerminal('t3', status: _status('idle'), pid: 9),
          ),
        ),
        9,
      );
      expect(
        claudePid(
          HcTerminal.fromJson(
            hcTerminal('rohan/t3', status: _status('idle'), pid: 9),
          ),
        ),
        isNull,
        reason: 'a pid of another machine',
      );
    });
  });
}
