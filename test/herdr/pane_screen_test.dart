/// The pane screen with a fake server, on the real clock.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/herdr_connection.dart';
import 'package:shellherd/herdr/ui/pane_screen.dart';

import '../support/fake_herdr.dart';
import '../support/fake_snapshots.dart';
import '../support/live_widgets.dart';

Map<String, Object?> _session({
  String status = 'working',
  Map<String, Object?> names = const {'agent': 'claude'},
}) => fakeSnapshot(
  workspaces: [fakeWorkspace('w1', 1, 'api', status)],
  tabs: [fakeTab('w1', 'server', status)],
  panes: [fakePane('w1:p1', 'w1', status, names)],
);

void main() {
  LiveTestWidgetsFlutterBinding.ensureInitialized();

  late FakeLink link;
  late HerdrConnection connection;

  FakeHerdr herdr() => link.herdr;
  Finder chip(String label) => find.widgetWithText(Chip, label);
  Finder paneText(String part) => find.textContaining(part, findRichText: true);

  Future<void> open(WidgetTester tester, {Map<String, Object?>? session}) async {
    link = FakeLink(session ?? _session());
    herdr().paneText = '\x1b[31mred line\x1b[0m\r\nlast line';
    connection = HerdrConnection(
      () async => link.open,
      backoff: (_) => const Duration(minutes: 1),
      debounce: const Duration(milliseconds: 1),
    )..connect();
    await tester.pumpWidget(
      MaterialApp(
        home: PaneScreen(connection: connection, paneId: 'w1:p1'),
      ),
    );
    await untilFound(tester, chip('live'));
    await untilFound(tester, paneText('last line'));
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    connection.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
  }

  String typed(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  testWidgets('shows the text, its place and the state of the link', (
    tester,
  ) async {
    await open(tester);
    expect(paneText('red line'), findsOneWidget);
    expect(find.text('claude'), findsOneWidget);
    expect(find.text('api › server › w1:p1'), findsOneWidget);
    expect(chip('live'), findsOneWidget);
    await close(tester);
  });

  testWidgets('the newest line is at the bottom', (tester) async {
    await open(tester);
    expect(
      tester.getTopLeft(paneText('red line')).dy,
      lessThan(tester.getTopLeft(paneText('last line')).dy),
    );
    await close(tester);
  });

  testWidgets('new text appears', (tester) async {
    await open(tester);
    herdr().paneText = 'something new';
    await untilFound(tester, paneText('something new'));
    expect(paneText('red line'), findsNothing);
    await close(tester);
  });

  testWidgets('a tap on a key sends it', (tester) async {
    await open(tester);
    await tester.tap(find.text('ctrl+c'));
    await until(tester, () => herdr().inputs.isNotEmpty, 'the key');
    expect(herdr().inputs.single.$1, 'pane.send_keys');
    expect(herdr().inputs.single.$2['keys'], ['ctrl+c']);
    await close(tester);
  });

  testWidgets('the key bar has a sideways key under its herdr name', (
    tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('shift+tab'));
    await until(tester, () => herdr().inputs.isNotEmpty, 'the key');
    expect(herdr().inputs.single.$2['keys'], ['shift+tab']);
    await close(tester);
  });

  testWidgets('send prompts the agent and empties the field', (tester) async {
    await open(tester);
    expect(find.text('prompt claude…'), findsOneWidget);
    await type(tester, 'fix the bug');
    await tester.tap(find.text('send'));
    await until(tester, () => typed(tester).isEmpty, 'the field to empty');
    expect(herdr().inputs.single.$1, 'agent.prompt');
    expect(herdr().inputs.single.$2['text'], 'fix the bug');
    await close(tester);
  });

  testWidgets('a pane without an agent gets the text and Enter', (
    tester,
  ) async {
    await open(tester, session: _session(status: 'idle', names: const {}));
    expect(find.text('type to the shell…'), findsOneWidget);
    await type(tester, 'ls');
    await tester.tap(find.text('send'));
    await until(tester, () => herdr().inputs.isNotEmpty, 'the input');
    expect(herdr().inputs.single.$1, 'pane.send_input');
    expect(herdr().inputs.single.$2['keys'], ['enter']);
    await close(tester);
  });

  testWidgets('send needs text', (tester) async {
    await open(tester);
    FilledButton button() =>
        tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button().onPressed, isNull);
    await type(tester, '   ');
    expect(button().onPressed, isNull);
    await type(tester, 'x');
    expect(button().onPressed, isNotNull);
    await close(tester);
  });

  testWidgets('a second send waits for the first', (tester) async {
    await open(tester);
    herdr().holdInput = Completer();
    await type(tester, 'one');
    await tester.tap(find.text('send'));
    await until(tester, () => herdr().inputs.isNotEmpty, 'the input');
    await tester.pump();
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
    herdr().holdInput!.complete();
    herdr().holdInput = null;
    await until(tester, () => typed(tester).isEmpty, 'the field to empty');
    await close(tester);
  });

  testWidgets('text typed during a send stays', (tester) async {
    await open(tester);
    herdr().holdInput = Completer();
    await type(tester, 'one');
    await tester.tap(find.text('send'));
    await until(tester, () => herdr().inputs.isNotEmpty, 'the input');
    await type(tester, 'one more');
    herdr().holdInput!.complete();
    herdr().holdInput = null;
    await until(
      tester,
      () =>
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed !=
          null,
      'the send to end',
    );
    expect(typed(tester), 'one more');
    await close(tester);
  });

  testWidgets('a blocked agent keeps the text and says why', (tester) async {
    await open(tester);
    herdr().errors['agent.prompt'] = ['agent_blocked'];
    await type(tester, 'precious');
    await tester.tap(find.text('send'));
    await untilFound(
      tester,
      find.text('The agent is waiting for an answer. Your text was not sent.'),
    );
    expect(typed(tester), 'precious');
    expect(herdr().count('agent.prompt'), 1, reason: 'it does not send again');

    await tester.tap(find.text('OK'));
    await tester.pump();
    expect(find.textContaining('waiting for an answer'), findsNothing);
    await close(tester);
  });

  testWidgets('a timeout does not claim that nothing arrived', (tester) async {
    await open(tester);
    herdr().torn.add('agent.prompt');
    await type(tester, 'maybe');
    await tester.tap(find.text('send'));
    await untilFound(
      tester,
      find.text('No answer from herdr. The input may have arrived anyway.'),
    );
    expect(typed(tester), 'maybe');
    await close(tester);
  });

  testWidgets('send works again after a channel failure', (tester) async {
    await open(tester);
    herdr().broken.add('agent.prompt');
    await type(tester, 'again');
    await tester.tap(find.text('send'));
    await untilFound(
      tester,
      find.text('No answer from herdr. The input may have arrived anyway.'),
    );
    herdr().broken.clear();
    await tester.pump();
    await tester.tap(find.text('send'));
    await until(tester, () => typed(tester).isEmpty, 'the field to empty');
    expect(herdr().inputs.single.$2['text'], 'again');
    await close(tester);
  });

  testWidgets('leaving the pane drops the input that still waits', (
    tester,
  ) async {
    await open(tester);
    herdr().holdInput = Completer();
    await tester.tap(find.text('esc'));
    await until(tester, () => herdr().inputs.isNotEmpty, 'the first key');
    await tester.tap(find.text('enter'));
    await tester.pump();

    await tester.pumpWidget(const SizedBox());
    herdr().holdInput!.complete();
    herdr().holdInput = null;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(herdr().inputs, hasLength(1));
    expect(herdr().inputs.single.$2['keys'], ['esc']);
    connection.dispose();
  });

  testWidgets('a blocked agent gets the quick answers', (tester) async {
    await open(tester, session: _session(status: 'blocked'));
    expect(find.text('needs you'), findsOneWidget);
    await tester.tap(find.text('2'));
    await until(tester, () => herdr().inputs.isNotEmpty, 'the answer');
    expect(herdr().inputs.single.$1, 'pane.send_keys');
    expect(herdr().inputs.single.$2['keys'], ['2']);
    await close(tester);
  });

  testWidgets('the quick answers leave with the block', (tester) async {
    await open(tester, session: _session(status: 'blocked'));
    herdr().snapshotJson = _session();
    herdr().push();
    await untilGone(tester, find.text('needs you'));
    await close(tester);
  });

  testWidgets('an agent that is not blocked gets no quick answers', (
    tester,
  ) async {
    await open(tester);
    expect(find.text('needs you'), findsNothing);
    await close(tester);
  });

  testWidgets('the exact screen reads the visible source', (tester) async {
    await open(tester);
    herdr().paneTexts['visible'] = 'exact\r\n\r\nscreen';
    await tester.tap(find.byTooltip('Exact screen'));
    await untilFound(tester, paneText('exact'));
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(herdr().reads.last['source'], 'visible');

    await tester.tap(find.byTooltip('Text view'));
    await untilFound(tester, paneText('last line'));
    expect(find.byType(InteractiveViewer), findsNothing);
    await close(tester);
  });

  testWidgets('a closed pane says so and offers no input', (tester) async {
    await open(tester);
    herdr().errors['pane.read'] = ['pane_not_found'];
    await untilFound(tester, find.text('This pane is closed.'));
    expect(paneText('last line'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('esc'), findsNothing);
    await close(tester);
  });

  testWidgets('a dropped link dims the text; a tap sends nothing', (
    tester,
  ) async {
    await open(tester);
    link.done.complete();
    await untilFound(tester, chip('retrying'));
    expect(
      find.text('No link to herdr. This text may be old.'),
      findsOneWidget,
    );
    final opacity = tester.widget<Opacity>(
      find.ancestor(of: paneText('last line'), matching: find.byType(Opacity)).first,
    );
    expect(opacity.opacity, lessThan(1));

    await tester.tap(find.text('esc'));
    await untilFound(tester, find.text('No link to herdr. Nothing was sent.'));
    expect(herdr().inputs, isEmpty);
    await close(tester);
  });

  testWidgets('a failed read shows why', (tester) async {
    await open(tester);
    herdr().errors['pane.read'] = ['internal'];
    await untilFound(tester, find.text('Cannot read this pane.'));
    await untilGone(tester, find.text('Cannot read this pane.'));
    await close(tester);
  });

  testWidgets('the text stays still while the user reads further up', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester);
    herdr().paneText = [for (var i = 0; i < 100; i++) 'row $i'].join('\r\n');
    await untilFound(tester, paneText('row 99'));

    await tester.drag(find.byType(ListView).first, const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(paneText('row 99'), findsNothing);
    final before = tester.getTopLeft(paneText('row 80')).dy;

    herdr().paneText = [for (var i = 0; i < 101; i++) 'row $i'].join('\r\n');
    final after = herdr().count('pane.read');
    await until(tester, () => herdr().count('pane.read') > after + 1, 'reads');
    await tester.pump();
    expect(tester.getTopLeft(paneText('row 80')).dy, before);

    await tester.drag(find.byType(ListView).first, const Offset(0, -2000));
    await tester.pumpAndSettle();
    await untilFound(tester, paneText('row 100'));
    await close(tester);
  });

  testWidgets('long names and long lines fit a phone', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final long = 'very-long-name-' * 6;
    final session = fakeSnapshot(
      workspaces: [fakeWorkspace('w1', 1, long, 'blocked')],
      tabs: [fakeTab('w1', long, 'blocked')],
      panes: [fakePane('w1:p1', 'w1', 'blocked', {'agent': 'c', 'label': long})],
    );
    await open(tester, session: session);
    herdr().paneText = 'x' * 500;
    await untilFound(tester, paneText('xxxx'));
    expect(tester.takeException(), isNull);
    await close(tester);
  });
}
