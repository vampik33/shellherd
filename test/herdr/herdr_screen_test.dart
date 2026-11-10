/// The herdr lists and the link banners, with a fake server. On the real
/// clock, because the connection uses real timers.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/herdr_connection.dart';
import 'package:shellherd/herdr/ui/herdr_lists.dart';
import 'package:shellherd/herdr/ui/herdr_screen.dart';
import 'package:shellherd/ssh/host.dart';
import 'package:shellherd/ssh/known_hosts.dart';
import 'package:shellherd/ssh/ssh_connector.dart';

import '../support/fake_herdr.dart';
import '../support/live_widgets.dart';

Map<String, Object?> _workspace(
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

Map<String, Object?> _tab(String workspace, String label, String status) => {
  'tab_id': '$workspace:t1',
  'workspace_id': workspace,
  'number': 1,
  'label': label,
  'focused': false,
  'pane_count': 1,
  'agent_status': status,
};

Map<String, Object?> _pane(
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

Map<String, Object?> _agent(
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

Map<String, Object?> _snapshot({
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

Map<String, Object?> _busySession() => _snapshot(
  workspaces: [
    _workspace('w1', 1, 'api', 'blocked', panes: 2),
    _workspace('w2', 2, 'notes', 'idle'),
  ],
  tabs: [_tab('w1', 'server', 'blocked'), _tab('w2', 'one', 'idle')],
  panes: [
    _pane('w1:p1', 'w1', 'blocked', {'agent': 'claude', 'cwd': '/srv/api'}),
    _pane('w1:p2', 'w1', 'working', {'label': 'my pane', 'agent': 'codex'}),
    _pane('w2:p1', 'w2', 'idle', {}),
  ],
  agents: [
    _agent('w1:p4', 'w1', 'idle', {'agent': 'opencode'}),
    _agent('w1:p3', 'w1', 'working', {'name': 'reviewer', 'agent': 'claude'}),
    _agent('w1:p2', 'w1', 'done', {
      'display_agent': 'Codex CLI',
      'agent': 'codex',
    }),
    _agent('w1:p1', 'w1', 'blocked', {
      'agent': 'claude',
      'title': 'Allow edit?',
    }),
  ],
);

void main() {
  LiveTestWidgetsFlutterBinding.ensureInitialized();

  Host hostWith({String label = 'box', String? herdrSession}) => Host(
    id: 'h',
    label: label,
    address: 'pc',
    user: 'me',
    keyId: 'k',
    herdrSession: herdrSession,
  );
  final host = hostWith();
  const key = HostKey('ssh-ed25519', 'SHA256:x');
  late List<FutureOr<FakeLink> Function()> script;
  late List<FakeLink> links;
  late int terminals;
  late int connections;

  setUp(() {
    script = [];
    links = [];
    terminals = 0;
    connections = 0;
  });

  FakeLink Function() failing(Object error) =>
      () => throw error;

  Future<void> pumpScreen(WidgetTester tester, {Host? on}) => tester.pumpWidget(
    MaterialApp(
      home: HerdrScreen(
        host: on ?? host,
        createConnection: () {
          connections++;
          return HerdrConnection(
            () async {
              final next = await (script.isNotEmpty
                  ? script.removeAt(0)
                  : () => FakeLink(_busySession()))();
              links.add(next);
              return next.open;
            },
            backoff: (_) => const Duration(minutes: 1),
            debounce: const Duration(milliseconds: 1),
          );
        },
        onTerminal: () => terminals++,
      ),
    ),
  );

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  Finder chip(String label) => find.widgetWithText(Chip, label);
  Finder nav(String label) => find.widgetWithText(NavigationDestination, label);

  double opacityOf(WidgetTester tester, String text) => tester
      .widget<Opacity>(
        find
            .ancestor(of: find.text(text), matching: find.byType(Opacity))
            .first,
      )
      .opacity;

  Future<void> live(WidgetTester tester) => untilFound(tester, chip('live'));

  testWidgets('shows the agents that need attention first', (tester) async {
    await pumpScreen(tester);
    await live(tester);

    double y(Finder f) => tester.getTopLeft(f).dy;
    final blocked = find.text('claude');
    final done = find.text('Codex CLI');
    final working = find.text('reviewer');
    final idle = find.text('opencode');
    expect(y(find.text('needs you')), lessThan(y(blocked)));
    expect(y(blocked), lessThan(y(done)));
    expect(y(done), lessThan(y(find.text('reviewer'))));
    expect(y(working), lessThan(y(idle)));
    expect(find.text('Allow edit?'), findsOneWidget, reason: 'the title');
    expect(find.text('done'), findsOneWidget, reason: 'no title: the state');
    expect(find.text('api › server'), findsNWidgets(4));
    await close(tester);
  });

  testWidgets('each row has the dot of its state', (tester) async {
    await pumpScreen(tester);
    await live(tester);
    final dots = tester.widgetList<StatusDot>(find.byType(StatusDot));
    expect(dots.map((d) => d.status), [
      AgentStatus.blocked,
      AgentStatus.done,
      AgentStatus.working,
      AgentStatus.idle,
    ]);
    await close(tester);
  });

  testWidgets('spaces shows workspaces, tabs and panes', (tester) async {
    await pumpScreen(tester);
    await live(tester);
    await tester.tap(nav('spaces'));
    await tester.pump();

    double y(Finder f) => tester.getTopLeft(f).dy;
    expect(y(find.text('api')), lessThan(y(find.text('server'))));
    expect(y(find.text('server')), lessThan(y(find.text('claude'))));
    expect(y(find.text('claude')), lessThan(y(find.text('my pane'))));
    expect(y(find.text('my pane')), lessThan(y(find.text('notes'))));
    expect(find.text('2 panes'), findsOneWidget);
    expect(find.text('1 pane'), findsOneWidget);
    expect(find.text('/srv/api'), findsOneWidget);
    expect(find.text('w2:p1'), findsOneWidget, reason: 'no name: the id');
    await close(tester);
  });

  testWidgets('a pushed event updates the list', (tester) async {
    await pumpScreen(tester);
    await live(tester);
    final herdr = links.single.herdr;
    herdr.snapshotJson = _snapshot(
      workspaces: [_workspace('w1', 1, 'api', 'working')],
      tabs: [_tab('w1', 'server', 'working')],
      panes: [_pane('w1:p9', 'w1', 'working', {})],
      agents: [
        _agent('w1:p9', 'w1', 'working', {'agent': 'fresh'}),
      ],
    );
    herdr.push();
    await untilFound(tester, find.text('fresh'));
    expect(find.text('reviewer'), findsNothing);
    await close(tester);
  });

  testWidgets('an empty session says so', (tester) async {
    script.add(() => FakeLink(_snapshot()));
    await pumpScreen(tester);
    await live(tester);
    expect(find.text('No agents are running.'), findsOneWidget);
    await tester.tap(nav('spaces'));
    await tester.pump();
    expect(find.text('No spaces yet.'), findsOneWidget);
    await close(tester);
  });

  testWidgets('a drop keeps the list dimmed, and Now reconnects', (
    tester,
  ) async {
    await pumpScreen(tester);
    await live(tester);
    expect(opacityOf(tester, 'reviewer'), 1);

    links.single.done.complete();
    await untilFound(tester, find.textContaining('Retrying in'));
    expect(find.text('reviewer'), findsOneWidget);
    expect(opacityOf(tester, 'reviewer'), lessThan(1));
    expect(chip('retrying'), findsOneWidget);

    await tester.tap(find.text('Now'));
    await live(tester);
    expect(links, hasLength(2));
    expect(opacityOf(tester, 'reviewer'), 1);
    expect(find.textContaining('Retrying'), findsNothing);
    await close(tester);
  });

  testWidgets('the countdown goes down', (tester) async {
    script.add(failing(SshNetworkException(host, 'no route')));
    await pumpScreen(tester);
    await untilFound(tester, find.text('No link. Retrying in 60 s.'));
    await untilFound(tester, find.text('No link. Retrying in 59 s.'));
    expect(find.textContaining('no route'), findsOneWidget);
    await close(tester);
  });

  testWidgets('no server says so, and Retry finds a later one', (tester) async {
    script.add(
      failing(
        HerdrConnectException('ping', SSHChannelOpenError(1, 'no socket')),
      ),
    );
    await pumpScreen(tester);
    await untilFound(tester, find.text('herdr is not running on box.'));
    expect(chip('no herdr'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('Retry'));
    await live(tester);
    expect(find.text('herdr is not running on box.'), findsNothing);
    await close(tester);
  });

  testWidgets('a changed key shows both keys and offers no retry', (
    tester,
  ) async {
    const other = HostKey('ssh-ed25519', 'SHA256:other');
    script.add(failing(SshHostKeyChanged(host, key, other)));
    await pumpScreen(tester);
    await untilFound(tester, find.text('The host key of pc changed.'));
    expect(find.textContaining('SHA256:other'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(chip('failed'), findsOneWidget);
    await close(tester);
  });

  testWidgets('a refused login offers a retry', (tester) async {
    script.add(failing(SshAuthFailed(host, 'no')));
    await pumpScreen(tester);
    await untilFound(
      tester,
      find.text('The server refused the key for me@pc.'),
    );
    await tester.tap(find.text('Retry'));
    await live(tester);
    await close(tester);
  });

  testWidgets('an unreadable server says so', (tester) async {
    script.add(failing(const HerdrProtocolException('bad field')));
    await pumpScreen(tester);
    await untilFound(
      tester,
      find.text('herdr on box sent something this app cannot read.'),
    );
    expect(find.textContaining('bad field'), findsOneWidget);
    await close(tester);
  });

  testWidgets('terminal opens the terminal and keeps the tab', (tester) async {
    await pumpScreen(tester);
    await live(tester);
    await tester.tap(nav('terminal'));
    await tester.pump();
    expect(terminals, 1);
    expect(find.text('reviewer'), findsOneWidget);
    await close(tester);
  });

  testWidgets('the title shows the herdr session', (tester) async {
    await pumpScreen(tester, on: hostWith(herdrSession: 'work'));
    await live(tester);
    expect(find.text('box · work'), findsOneWidget);
    await close(tester);
  });

  testWidgets('building the screen again keeps its connection', (tester) async {
    await pumpScreen(tester);
    await live(tester);
    await pumpScreen(tester);
    await tester.pump();
    expect(connections, 1);
    expect(chip('live'), findsOneWidget);
    expect(links.single.closed, isFalse);
    await close(tester);
  });

  testWidgets('long names fit a phone', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final long = 'very-long-name-' * 6;
    script.add(
      () => FakeLink(
        _snapshot(
          workspaces: [_workspace('w1', 1, long, 'blocked')],
          tabs: [_tab('w1', long, 'blocked')],
          panes: [
            _pane('w1:p1', 'w1', 'blocked', {'label': long, 'cwd': '/$long'}),
          ],
          agents: [
            _agent('w1:p1', 'w1', 'blocked', {'agent': long, 'title': long}),
          ],
        ),
      ),
    );
    await pumpScreen(
      tester,
      on: hostWith(label: long, herdrSession: long),
    );
    await live(tester);
    await tester.tap(nav('spaces'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await close(tester);
  });

  testWidgets('leaving the screen closes the link', (tester) async {
    await pumpScreen(tester);
    await live(tester);
    final link = links.single;
    await close(tester);
    await until(tester, () => link.closed, 'the link to close');
    expect(link.herdr.subscriptions.single.closed, isTrue);
  });
}
