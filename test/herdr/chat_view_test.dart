/// The pane screen's chat, fed by a fake transcript read, on the real clock.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/herdr_connection.dart';
import 'package:shellherd/herdr/transcript/chat_items.dart';
import 'package:shellherd/herdr/transcript/transcript_stream.dart';
import 'package:shellherd/herdr/ui/chat_details.dart';
import 'package:shellherd/herdr/ui/chat_view.dart';
import 'package:shellherd/herdr/ui/pane_screen.dart';

import '../support/fake_herdr.dart';
import '../support/fake_snapshots.dart';
import '../support/fake_transcripts.dart';
import '../support/live_widgets.dart';

const _session1 = '0d6c1f3e-1b2a-4c5d-8e9f-0a1b2c3d4e5f';

Map<String, Object?> _session({
  String status = 'working',
  bool transcript = true,
}) => fakeSnapshot(
  workspaces: [fakeWorkspace('w1', 1, 'api', status)],
  tabs: [fakeTab('w1', 'server', status)],
  panes: [
    fakePane('w1:p1', 'w1', status, {
      'agent': 'claude',
      if (transcript)
        'agent_session': {
          'source': 'herdr:claude',
          'agent': 'claude',
          'kind': 'id',
          'value': _session1,
        },
    }),
  ],
);

final _lines = [
  claudeUser('fix the login bug', uuid: 'u1'),
  claudeAssistant([
    {'type': 'thinking', 'thinking': 'secret thoughts', 'signature': 's'},
  ], uuid: 'a1'),
  claudeAssistant([
    claudeText('I found it in **auth.dart**: `retry` was off.'),
  ], uuid: 'a2'),
  claudeAssistant([
    claudeToolUse('t1', 'Bash', {
      'command': 'flutter test --name login',
      'description': 'Run the login tests',
    }),
  ], uuid: 'a3'),
  claudeUser([claudeToolResult('t1', 'All tests passed!')], uuid: 'u2'),
];

void main() {
  LiveTestWidgetsFlutterBinding.ensureInitialized();

  late FakeLink link;
  late FakeTranscripts transcripts;
  late HerdrConnection connection;
  late ChatDetails details;

  FakeHerdr herdr() => link.herdr;
  Finder paneText(String part) => find.textContaining(part, findRichText: true);

  /// Opens the pane and waits until the transcript is being read.
  Future<void> open(
    WidgetTester tester, {
    Map<String, Object?>? session,
    bool withTranscripts = true,
    bool showDetails = true,
    FakeTranscriptRanges? ranges,
  }) async {
    transcripts = FakeTranscripts();
    details = ChatDetails()..value = showDetails;
    link = FakeLink(
      session ?? _session(),
      null,
      withTranscripts ? transcripts.open : null,
      null,
      ranges?.read,
    );
    herdr().paneText = 'pane text line';
    connection = HerdrConnection(
      () async => link.open,
      backoff: (_) => const Duration(minutes: 1),
      debounce: const Duration(milliseconds: 1),
    )..connect();
    await tester.pumpWidget(
      MaterialApp(
        home: PaneScreen(
          connection: connection,
          paneId: 'w1:p1',
          chatDetails: details,
        ),
      ),
    );
  }

  Future<void> openChat(
    WidgetTester tester, {
    Map<String, Object?>? session,
    bool showDetails = true,
  }) async {
    await open(tester, session: session, showDetails: showDetails);
    await until(
      tester,
      () => transcripts.opened.isNotEmpty,
      'a transcript read',
    );
    expect(transcripts.last.session, _session1);
    transcripts.last.file(_lines);
    await untilFound(tester, paneText('fix the login bug'));
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    connection.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  testWidgets('a Claude pane shows its conversation, not its text', (
    tester,
  ) async {
    await openChat(tester);
    expect(paneText('I found it in auth.dart'), findsOneWidget);
    expect(paneText('pane text line'), findsNothing);
    expect(find.byTooltip('Exact screen'), findsOneWidget);
    // The poller rests while the chat shows.
    final reads = herdr().count('pane.read');
    await Future<void>.delayed(const Duration(seconds: 1));
    await tester.pump();
    expect(herdr().count('pane.read'), reads);
    await close(tester);
  });

  testWidgets('thinking and tool calls stay hidden until the switch shows '
      'them, and hide again', (tester) async {
    await openChat(tester, showDetails: false);
    expect(paneText('I found it in auth.dart'), findsOneWidget);
    expect(find.text('Bash'), findsNothing);
    expect(find.text('Thinking'), findsNothing);
    await tester.tap(find.byTooltip('Show thinking and tool calls'));
    await tester.pump();
    expect(details.value, isTrue);
    expect(find.text('Run the login tests'), findsOneWidget);
    expect(find.text('Thinking'), findsOneWidget);
    await tester.tap(find.byTooltip('Hide thinking and tool calls'));
    await tester.pump();
    expect(details.value, isFalse);
    expect(find.text('Bash'), findsNothing);
    expect(paneText('fix the login bug'), findsOneWidget);
    await close(tester);
  });

  testWidgets('the switch is only there while the chat shows', (tester) async {
    await openChat(tester);
    expect(find.byTooltip('Hide thinking and tool calls'), findsOneWidget);
    await tester.tap(find.byTooltip('Exact screen'));
    await tester.pump();
    expect(find.byTooltip('Hide thinking and tool calls'), findsNothing);
    await close(tester);
  });

  /// [ChatView] alone, on a plain screen.
  Future<void> pumpChat(
    WidgetTester tester,
    List<ChatItem> items, {
    bool showDetails = true,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ChatView(items: items, showDetails: showDetails),
      ),
    ),
  );

  testWidgets('without details a turn keeps its order and new replies come', (
    tester,
  ) async {
    await pumpChat(tester, showDetails: false, const [
      ChatPrompt('first prompt'),
      ChatThinking('hmm'),
      ChatTool(id: 't1', name: 'Read', summary: 'a.dart', input: '{}'),
      ChatReply('first reply'),
      ChatNote('Interrupted'),
      ChatPrompt('second prompt'),
      ChatTool(id: 't2', name: 'Bash', summary: 'ls', input: '{}'),
    ]);
    double top(String text) =>
        tester.getTopLeft(find.textContaining(text, findRichText: true)).dy;
    expect(find.text('Read'), findsNothing);
    expect(find.text('Bash'), findsNothing);
    expect(top('first prompt'), lessThan(top('first reply')));
    expect(top('first reply'), lessThan(top('Interrupted')));
    expect(top('Interrupted'), lessThan(top('second prompt')));
  });

  testWidgets('hiding details at the bottom of a held chat shows what came', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final tools = [
      for (var i = 0; i < 200; i++)
        ChatTool(id: 't$i', name: 'Read', summary: 'f$i', input: '{}'),
    ];
    Future<void> show(List<ChatItem> items, {bool showDetails = true}) =>
        pumpChat(tester, items, showDetails: showDetails);
    final before = [const ChatPrompt('the prompt'), ...tools];
    await show(before);
    await tester.fling(find.byType(ListView), const Offset(0, 3000), 3000);
    await tester.pumpAndSettle();

    final after = [...before, const ChatReply('the reply')];
    await show(after);
    await tester.pumpAndSettle();
    expect(find.textContaining('the reply', findRichText: true), findsNothing);

    await show(after, showDetails: false);
    await tester.pumpAndSettle();
    expect(
      find.textContaining('the reply', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('hiding details further up keeps the chat still', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<void> show(List<ChatItem> items, {bool showDetails = true}) =>
        pumpChat(tester, items, showDetails: showDetails);
    final before = [
      for (var i = 0; i < 60; i++) ChatPrompt('message $i'),
      for (var i = 0; i < 20; i++)
        ChatTool(id: 't$i', name: 'Read', summary: 'f$i', input: '{}'),
    ];
    await show(before);
    await tester.drag(find.byType(ListView), const Offset(0, 150));
    await tester.pumpAndSettle();

    final after = [...before, const ChatReply('the reply')];
    await show(after);
    await show(after, showDetails: false);
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    expect(scroll.position.pixels, greaterThan(1));
    expect(
      find.textContaining('the reply', findRichText: true, skipOffstage: false),
      findsNothing,
    );

    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('the reply', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('only hidden rows is no conversation yet', (tester) async {
    await pumpChat(tester, showDetails: false, const [ChatThinking('hmm')]);
    expect(find.text('No messages yet.'), findsOneWidget);
  });

  testWidgets('tool calls and thinking start closed and open on a tap', (
    tester,
  ) async {
    await openChat(tester);
    expect(find.text('Bash'), findsOneWidget);
    expect(find.text('Run the login tests'), findsOneWidget);
    expect(paneText('flutter test --name login'), findsNothing);
    expect(paneText('All tests passed!'), findsNothing);
    await tester.tap(find.text('Run the login tests'));
    await tester.pump();
    expect(paneText('flutter test --name login'), findsOneWidget);
    expect(paneText('All tests passed!'), findsOneWidget);

    expect(paneText('secret thoughts'), findsNothing);
    await tester.tap(find.text('Thinking'));
    await tester.pump();
    expect(paneText('secret thoughts'), findsOneWidget);
    await close(tester);
  });

  testWidgets('an open row stays open as new messages come', (tester) async {
    await openChat(tester);
    await tester.tap(find.text('Run the login tests'));
    await tester.pump();
    transcripts.last.text(
      '${claudeAssistant([claudeText('Done.')], uuid: 'a9')}\n',
    );
    await untilFound(tester, paneText('Done.'));
    expect(paneText('All tests passed!'), findsOneWidget);
    await close(tester);
  });

  testWidgets('an open tool call stays open when a new read starts further '
      'on', (tester) async {
    await openChat(tester);
    await tester.tap(find.text('Run the login tests'));
    await tester.pump();
    expect(paneText('All tests passed!'), findsOneWidget);
    transcripts.last.close();
    await until(tester, () => transcripts.opened.length == 2, 'a new read');
    // The new read starts two records later, as after the file grew.
    transcripts.last.file(_lines.skip(2).toList());
    await untilGone(tester, paneText('fix the login bug'));
    expect(paneText('All tests passed!'), findsOneWidget);
    await close(tester);
  });

  testWidgets('until the first message the pane shows its text, then the '
      'chat', (tester) async {
    await open(tester);
    await until(tester, () => transcripts.opened.isNotEmpty, 'a read');
    // Claude Code has not written its transcript yet.
    transcripts.last.header(0);
    await untilFound(tester, paneText('pane text line'));
    expect(find.text('No messages yet.'), findsNothing);
    transcripts.last.text('${claudeUser('first prompt', uuid: 'u1')}\n');
    await untilFound(tester, paneText('first prompt'));
    expect(paneText('pane text line'), findsNothing);
    // The poller rests again.
    final reads = herdr().count('pane.read');
    await Future<void>.delayed(const Duration(seconds: 1));
    await tester.pump();
    expect(herdr().count('pane.read'), reads);
    await close(tester);
  });

  testWidgets("the text view's error does not stay over the chat", (
    tester,
  ) async {
    await open(tester);
    herdr().errors['pane.read'] = [
      for (var i = 0; i < 1000; i++) 'internal_error',
    ];
    await until(tester, () => transcripts.opened.isNotEmpty, 'a read');
    transcripts.last.header(0);
    await untilFound(tester, find.text('Cannot read this pane.'));
    transcripts.last.text('${claudeUser('first prompt', uuid: 'u1')}\n');
    await untilFound(tester, paneText('first prompt'));
    expect(find.text('Cannot read this pane.'), findsNothing);
    await close(tester);
  });

  testWidgets('a pane that closes while the chat comes says so', (
    tester,
  ) async {
    await open(tester);
    await until(tester, () => transcripts.opened.isNotEmpty, 'a read');
    transcripts.last.header(0);
    await untilFound(tester, paneText('pane text line'));
    // The next read of the text finds the pane closed, but its answer
    // comes only after the chat is on the screen.
    final hold = herdr().holdReads = Completer();
    herdr().errors['pane.read'] = ['pane_not_found'];
    final reads = herdr().count('pane.read');
    await until(
      tester,
      () => herdr().count('pane.read') > reads,
      'a read on its way',
    );
    transcripts.last.text('${claudeUser('first prompt', uuid: 'u1')}\n');
    await untilFound(tester, paneText('first prompt'));
    expect(find.byType(TextField), findsOneWidget);
    hold.complete();
    await untilFound(tester, find.text('This pane is closed.'));
    expect(paneText('first prompt'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('esc'), findsNothing);
    await close(tester);
  });

  testWidgets('an image in a reply is not fetched', (tester) async {
    await open(tester);
    await until(tester, () => transcripts.opened.isNotEmpty, 'a read');
    transcripts.last.file([
      claudeAssistant([
        claudeText('Look: ![chart](https://example.com/x.png)'),
      ]),
    ]);
    await untilFound(tester, paneText('[image: chart]'));
    expect(find.byType(Image), findsNothing);
    await close(tester);
  });

  testWidgets('a working agent has a line under the last message; the start '
      'of a long transcript says older messages are not shown', (tester) async {
    await open(tester);
    await until(tester, () => transcripts.opened.isNotEmpty, 'a read');
    final body = '${claudeUser('cut off')}\n${claudeUser('kept')}\n';
    transcripts.last
      ..header(1 << 30)
      ..text(body);
    // A cut read shows once its whole tail came; here the test ends the
    // read early, which shows what came.
    transcripts.last.close();
    await untilFound(tester, paneText('kept'));
    expect(paneText('cut off'), findsNothing);
    expect(find.text('Earlier messages are not shown.'), findsOneWidget);
    expect(find.text('working…'), findsOneWidget);
    await close(tester);
  });

  testWidgets("a blocked agent shows the pane's text and the answers, not "
      'the chat', (tester) async {
    await open(tester, session: _session(status: 'blocked'));
    await until(tester, () => transcripts.opened.isNotEmpty, 'a read');
    transcripts.last.file([
      claudeUser('clean up', uuid: 'u1'),
      claudeAssistant([
        claudeToolUse('t1', 'Bash', {'command': 'rm -rf build'}),
      ], uuid: 'a1'),
    ]);
    await untilFound(tester, paneText('pane text line'));
    expect(find.text('needs you'), findsOneWidget);
    await tester.tap(find.text('1'));
    await until(tester, () => herdr().inputs.isNotEmpty, 'the answer');
    expect(herdr().inputs.single.$1, 'pane.send_keys');
    expect(herdr().inputs.single.$2['keys'], ['1']);
    // The transcript was read meanwhile: the chat and its tool calls stay
    // away.
    expect(paneText('clean up'), findsNothing);
    expect(find.text('Bash'), findsNothing);
    expect(find.text('Show screen'), findsNothing);
    expect(find.byTooltip('Exact screen'), findsOneWidget);
    await close(tester);
  });

  testWidgets('the chat steps aside while the agent is blocked and comes '
      'back after', (tester) async {
    await openChat(tester);
    expect(paneText('pane text line'), findsNothing);
    herdr()
      ..snapshotJson = _session(status: 'blocked')
      ..push();
    await untilFound(tester, paneText('pane text line'));
    expect(find.text('needs you'), findsOneWidget);
    expect(paneText('fix the login bug'), findsNothing);
    herdr()
      ..snapshotJson = _session()
      ..push();
    await untilFound(tester, paneText('fix the login bug'));
    expect(paneText('pane text line'), findsNothing);
    expect(find.text('needs you'), findsNothing);
    await close(tester);
  });

  testWidgets('the toggle goes to the exact screen and back to the chat', (
    tester,
  ) async {
    await openChat(tester);
    await tester.tap(find.byTooltip('Exact screen'));
    await untilFound(tester, paneText('pane text line'));
    expect(paneText('fix the login bug'), findsNothing);
    await tester.tap(find.byTooltip('Chat'));
    await untilFound(tester, paneText('fix the login bug'));
    await close(tester);
  });

  testWidgets('the exact screen the user chose stays when the snapshot '
      'changes', (tester) async {
    await openChat(tester);
    await tester.tap(find.byTooltip('Exact screen'));
    await untilFound(tester, find.byTooltip('Chat'));
    herdr()
      ..snapshotJson = _session(status: 'done')
      ..push();
    await until(
      tester,
      () =>
          connection.snapshot.value?.pane('w1:p1')?.status == AgentStatus.done,
      'the new snapshot',
    );
    await tester.pump();
    expect(find.byTooltip('Chat'), findsOneWidget);
    expect(paneText('pane text line'), findsOneWidget);
    expect(paneText('fix the login bug'), findsNothing);
    await close(tester);
  });

  testWidgets('a pane without a transcript shows its text', (tester) async {
    await open(tester, session: _session(transcript: false));
    await untilFound(tester, paneText('pane text line'));
    expect(transcripts.opened, isEmpty);
    await tester.tap(find.byTooltip('Exact screen'));
    await untilFound(tester, find.byTooltip('Text view'));
    await close(tester);
  });

  testWidgets('a server without transcript reads shows the text', (
    tester,
  ) async {
    await open(tester, withTranscripts: false);
    await untilFound(tester, paneText('pane text line'));
    await close(tester);
  });

  testWidgets('a transcript that cannot be read falls back to the text and '
      'says why', (tester) async {
    await open(tester);
    await until(tester, () => transcripts.opened.isNotEmpty, 'a read');
    transcripts.last.fail(StateError('exit 66: cannot read'));
    await untilFound(
      tester,
      find.text("Cannot read the conversation. This is the pane's text."),
    );
    await untilFound(tester, paneText('pane text line'));
    await close(tester);
  });

  testWidgets('a dropped link dims the chat and keeps it', (tester) async {
    await openChat(tester);
    link.done.complete();
    await untilFound(
      tester,
      find.text('No link to herdr. This text may be old.'),
    );
    expect(paneText('fix the login bug'), findsOneWidget);
    final opacity = tester.widget<Opacity>(
      find
          .ancestor(
            of: paneText('fix the login bug'),
            matching: find.byType(Opacity),
          )
          .first,
    );
    expect(opacity.opacity, lessThan(1));
    await close(tester);
  });

  testWidgets('the chat stays still while the user reads further up', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await open(tester);
    await until(tester, () => transcripts.opened.isNotEmpty, 'a read');
    transcripts.last.file([
      for (var i = 0; i < 60; i++) claudeUser('message $i', uuid: 'u$i'),
    ]);
    await untilFound(tester, paneText('message 59'));

    await tester.drag(find.byType(ListView).first, const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(paneText('message 59'), findsNothing);
    final before = tester.getTopLeft(paneText('message 50')).dy;

    transcripts.last.text('${claudeUser('message 60', uuid: 'u60')}\n');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
    expect(tester.getTopLeft(paneText('message 50')).dy, before);

    await tester.drag(find.byType(ListView).first, const Offset(0, -3000));
    await tester.pumpAndSettle();
    await untilFound(tester, paneText('message 60'));
    await close(tester);
  });

  group('earlier messages', () {
    String prompt(int i) => claudeUser('msg $i.', uuid: 'u$i');

    /// Opens the chat on [lines] read from inside line [cutLine], as for a
    /// file bigger than the read's tail.
    Future<void> openCut(
      WidgetTester tester,
      List<String> lines,
      int cutLine, {
      FakeTranscriptRanges? ranges,
    }) async {
      final file = transcriptFile(lines);
      ranges?.file = file;
      await open(tester, ranges: ranges);
      await until(tester, () => transcripts.opened.isNotEmpty, 'a read');
      final cut = transcriptFile(lines.take(cutLine).toList()).length + 2;
      transcripts.last
        ..header(file.length, start: cut)
        ..bytes(file.sublist(cut));
    }

    testWidgets('scrolling to the top loads them above, and the chat stays '
        'still', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final ranges = FakeTranscriptRanges()..hold = Completer();
      final lines = [for (var i = 0; i < 60; i++) prompt(i)];
      await openCut(tester, lines, 30, ranges: ranges);
      await untilFound(tester, paneText('msg 59.'));
      expect(ranges.asked, isEmpty, reason: 'the top is far away');

      await tester.drag(find.byType(ListView).first, const Offset(0, 5000));
      await untilStill(tester);
      await untilFound(tester, find.text('Loading earlier messages…'));
      expect(ranges.asked, hasLength(1));
      await untilStill(tester, paneText('msg 31.'));
      final before = tester.getTopLeft(paneText('msg 31.')).dy;

      ranges.hold!.complete();
      await until(
        tester,
        () => find.text('Loading earlier messages…').evaluate().isEmpty,
        'the load',
      );
      await tester.pump();
      expect(tester.getTopLeft(paneText('msg 31.')).dy, before);
      expect(ranges.asked, hasLength(1));

      await tester.drag(find.byType(ListView).first, const Offset(0, 5000));
      await untilStill(tester);
      await untilFound(tester, paneText('msg 0.'));
      expect(paneText('msg 30.'), findsNothing, reason: 'msg 30 is far below');
      await close(tester);
    });

    testWidgets('a short chat loads them at once, and an open row stays '
        'open', (tester) async {
      final ranges = FakeTranscriptRanges()..hold = Completer();
      final lines = [
        for (var i = 0; i < 5; i++) prompt(i),
        claudeAssistant([
          {'type': 'thinking', 'thinking': 'deep thought', 'signature': 's'},
        ], uuid: 'a1'),
        prompt(9),
      ];
      await openCut(tester, lines, 3, ranges: ranges);
      await untilFound(tester, paneText('msg 9.'));
      await until(tester, () => ranges.asked.isNotEmpty, 'a load');
      await tester.tap(find.text('Thinking'));
      await tester.pump();
      expect(paneText('deep thought'), findsOneWidget);

      ranges.hold!.complete();
      await untilFound(tester, paneText('msg 0.'));
      expect(paneText('deep thought'), findsOneWidget);
      expect(find.text('Loading earlier messages…'), findsNothing);
      expect(ranges.asked, hasLength(1));
      await close(tester);
    });

    testWidgets('a failed load offers to try again', (tester) async {
      final ranges = FakeTranscriptRanges()
        ..failNext = StateError('link stalled');
      final lines = [for (var i = 0; i < 4; i++) prompt(i)];
      await openCut(tester, lines, 1, ranges: ranges);
      await untilFound(
        tester,
        find.text('Cannot load earlier messages. Tap to try again.'),
      );
      expect(paneText('msg 0.'), findsNothing);
      await tester.tap(
        find.text('Cannot load earlier messages. Tap to try again.'),
      );
      await untilFound(tester, paneText('msg 0.'));
      expect(ranges.asked, hasLength(2));
      await close(tester);
    });

    testWidgets('a link without range reads says they are not shown', (
      tester,
    ) async {
      final lines = [for (var i = 0; i < 4; i++) prompt(i)];
      await openCut(tester, lines, 1);
      await untilFound(tester, find.text('Earlier messages are not shown.'));
      expect(paneText('msg 0.'), findsNothing);
      await close(tester);
    });

    testWidgets('an item that loads in front in place of a later copy shows '
        'once', (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      const tool = ChatTool(
        id: 't7',
        name: 'Bash',
        summary: 'only once',
        input: 'ls',
      );
      final later = [for (var i = 1; i < 60; i++) ChatPrompt('msg $i.')];
      Widget chat(List<ChatItem> items, int firstKey) => MaterialApp(
        home: Scaffold(
          body: ChatView(
            items: items,
            firstKey: firstKey,
            startsCut: true,
            onLoadEarlier: () {},
          ),
        ),
      );
      await tester.pumpWidget(chat([tool, ...later], 0));
      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pump();
      await untilFound(tester, paneText('only once'));
      // The earlier lines hold the record with the call: its later copy
      // is dropped, and the items shift by one less than came in front.
      await tester.pumpWidget(
        chat([const ChatPrompt('msg 0.'), tool, ...later], -2),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(paneText('only once'), findsOneWidget);
      expect(paneText('msg 0.'), findsOneWidget);
    });

    testWidgets('while nothing can load them, it says they are not shown', (
      tester,
    ) async {
      var loads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatView(
              items: const [ChatPrompt('hi')],
              startsCut: true,
              earlier: EarlierLoad.none,
              onLoadEarlier: () => loads++,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Earlier messages are not shown.'), findsOneWidget);
      expect(loads, 0);
    });

    testWidgets('past the cap it says they are not loaded', (tester) async {
      var loads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatView(
              items: const [ChatPrompt('hi')],
              startsCut: true,
              earlier: EarlierLoad.capped,
              onLoadEarlier: () => loads++,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Earlier messages are not loaded.'), findsOneWidget);
      expect(loads, 0);
    });
  });
}
