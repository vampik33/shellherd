/// The path a user takes to the herdr lists, against a throwaway sshd on
/// 127.0.0.1 and a real herdr server. Skipped when one of them is missing.
@Tags(['herdr'])
@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/app.dart';
import 'package:shellherd/herdr/ui/chat_view.dart';
import 'package:shellherd/herdr/ui/herdr_lists.dart';
import 'package:shellherd/ssh/host.dart';

import '../support/fake_transcripts.dart';
import '../support/herdr_test_session.dart';
import '../support/live_widgets.dart';
import '../support/memory_secret_store.dart';
import '../support/test_sshd.dart';

/// [part] in the pane text. find.text would also match the composer, which
/// holds a prompt until herdr takes it.
Finder inPane(String part) => find.byWidgetPredicate(
  (w) => w is RichText && w.text.toPlainText().contains(part),
);

Future<void> main() async {
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  final skip =
      !await HerdrTestSession.herdrAvailable() || TestSshd.binary == null;

  /// Opens the one saved host of a new app, which leads to herdr on [herdr]
  /// over a throwaway sshd, and waits for the link.
  Future<void> openHost(
    WidgetTester tester,
    HerdrTestSession herdr, {
    Map<String, String> env = const {},
  }) async {
    final dir = await Directory.systemTemp.createTemp('shellherd-herdr-');
    addTearDown(() => dir.delete(recursive: true));
    final sshd = await TestSshd.start(env: env);
    addTearDown(sshd.stop);
    final services = AppServices(dataDir: dir, secrets: MemorySecretStore());
    final keyId = await services.keys.generate();
    await sshd.authorize(await services.keys.publicLine(keyId));
    await services.hosts.save(
      Host(
        id: 'h1',
        label: 'testbox',
        address: '127.0.0.1',
        port: sshd.port,
        user: Platform.environment['USER']!,
        keyId: keyId,
        herdrSession: herdr.name,
      ),
    );
    await tester.pumpWidget(ShellherdApp(services));
    await untilFound(tester, find.text('testbox'));
    await tester.tap(find.text('testbox'));
    await untilFound(tester, find.text('Trust'));
    await tester.tap(find.text('Trust'));
    await untilFound(tester, find.widgetWithText(Chip, 'live'));
  }

  testWidgets('a tap on a host opens its agents and spaces', skip: skip, (
    tester,
  ) async {
    final herdr = await HerdrTestSession.start();
    addTearDown(herdr.stop);
    final pane = await herdr.createWorkspace('myspace');
    Finder chip(String label) => find.widgetWithText(Chip, label);
    Finder nav(String label) =>
        find.widgetWithText(NavigationDestination, label);

    await openHost(tester, herdr);
    expect(find.text('No agents are running.'), findsOneWidget);

    await herdr.client.request('pane.report_agent', {
      'pane_id': pane,
      'source': 'test',
      'agent': 'claude',
      'state': 'blocked',
    });
    await untilFound(tester, find.text('needs you'));
    expect(find.text('claude'), findsOneWidget);
    expect(find.text('myspace › 1'), findsOneWidget);

    await tester.tap(nav('spaces'));
    await tester.pump();
    expect(find.text('myspace'), findsOneWidget);

    await tester.tap(nav('terminal'));
    await untilFound(tester, chip('ssh'));

    await tester.pumpWidget(const SizedBox()); // closes the connections
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  testWidgets('a pane shows its text and takes input', skip: skip, (
    tester,
  ) async {
    final herdr = await HerdrTestSession.start();
    addTearDown(herdr.stop);
    final pane = await herdr.createWorkspace('myspace');
    final dir = await Directory.systemTemp.createTemp('shellherd-agent-');
    addTearDown(() => dir.delete(recursive: true));
    // herdr takes a process with this name for an agent.
    await Link('${dir.path}/claude').create('/usr/bin/cat');
    Finder text(String part) => find.textContaining(part, findRichText: true);

    await openHost(tester, herdr);
    await tester.tap(find.widgetWithText(NavigationDestination, 'spaces'));
    await tester.pump();
    final snapshot = await herdr.client.snapshot();
    final row = snapshot.panes.singleWhere((p) => p.id == pane);
    await tester.tap(find.text(row.displayName));

    Future<void> submit(String input) async {
      await untilFound(tester, find.byType(TextField));
      await tester.enterText(find.byType(TextField), input);
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
    }

    await submit(r'echo mark-$((40+2))');
    await untilFound(tester, text('mark-42'));

    await submit('sleep 100');
    await until(
      tester,
      () => tester.widget<TextField>(find.byType(TextField)).controller!.text.isEmpty,
      'the sent text to leave the field',
    );
    await tester.tap(find.text('ctrl+c'));
    await untilFound(tester, text('^C'));

    // A herdr pane opens on the exact screen, streamed over SSH.
    expect(find.byType(InteractiveViewer), findsOneWidget);
    await tester.tap(find.byTooltip('Text view'));
    await until(
      tester,
      () =>
          find.byType(InteractiveViewer).evaluate().isEmpty &&
          text('mark-42').evaluate().isNotEmpty,
      'the text view',
    );

    await submit('${dir.path}/claude');
    await untilFound(tester, find.text('prompt claude…'));
    await submit('hello-agent');
    await untilFound(tester, inPane('hello-agent'));

    await tester.pumpWidget(const SizedBox()); // closes the connections
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  /// Scrolls the list of the open pane by [dy] until [found] shows: up,
  /// toward what is above, by default.
  Future<void> scrollUpUntil(
    WidgetTester tester,
    Finder found, {
    double dy = 500,
  }) async {
    // Jumps by [dy]: a drag flings on in real time between the checks,
    // and can carry [found] past the screen unseen.
    final list = find.descendant(
      of: find.byType(ListView).first,
      matching: find.byType(Scrollable),
    );
    // A load reads over SSH: the time it may take bounds the scroll.
    final clock = Stopwatch()..start();
    while (found.evaluate().isEmpty && clock.elapsed.inSeconds < 30) {
      final at = tester.state<ScrollableState>(list.first).position;
      at.jumpTo((at.pixels + dy).clamp(at.minScrollExtent, at.maxScrollExtent));
      await tester.pump();
    }
    if (found.evaluate().isNotEmpty) return;
    final top = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data ?? '')
        .where((t) => t.contains('lines') || t.contains('messages'));
    final shown = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((t) => t.text.toPlainText())
        .where((t) => t.trim().isNotEmpty)
        .toList();
    fail(
      'no ${found.describeMatch(Plurality.one)}; lists: '
      '${find.byType(ListView).evaluate().length}; shows: '
      '${shown.take(8).join(' | ')} … ${shown.reversed.take(8).join(' | ')}; '
      'top: ${top.join(' | ')}; after ${clock.elapsed}',
    );
  }

  testWidgets('older lines of a pane load at the top of its text', skip: skip, (
    tester,
  ) async {
    final herdr = await HerdrTestSession.start();
    addTearDown(herdr.stop);
    final pane = await herdr.createWorkspace('myspace');
    Finder line(String text) => find.byWidgetPredicate(
      (w) => w is RichText && w.text.toPlainText() == text,
    );

    await openHost(tester, herdr);
    await tester.tap(find.widgetWithText(NavigationDestination, 'spaces'));
    await tester.pump();
    final snapshot = await herdr.client.snapshot();
    await tester.tap(
      find.text(snapshot.panes.singleWhere((p) => p.id == pane).displayName),
    );
    await untilFound(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), "seq -f 'row %g' 3000");
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.tap(find.byTooltip('Text view'));
    await untilFound(tester, line('row 3000'));

    // The first read has 400 lines; herdr gives at most 1000.
    await scrollUpUntil(tester, line('row 2200'));
    await untilGone(tester, find.text('Loading older lines…'));
    await scrollUpUntil(tester, line('row 2050'));
    expect(line('row 1500'), findsNothing);

    await tester.pumpWidget(const SizedBox()); // closes the connections
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  testWidgets('earlier messages of a long chat load at its top', skip: skip, (
    tester,
  ) async {
    // A prompt shows as selectable text.
    Finder message(String text) =>
        find.descendant(of: find.byType(ChatView), matching: find.text(text));
    final herdr = await HerdrTestSession.start();
    addTearDown(herdr.stop);
    final pane = await herdr.createWorkspace('myspace');
    final config = await Directory.systemTemp.createTemp('shellherd-claude-');
    addTearDown(() => config.delete(recursive: true));
    final projects = await Directory('${config.path}/projects/-tmp-app')
        .create(recursive: true);
    // About 5 MiB, mostly in tool calls the chat hides: the first read
    // has the last 2 MiB, and the rest loads in two or three more.
    final command = 'x' * 120000;
    final file = File('${projects.path}/s1.jsonl');
    await file.writeAsString(
      [
        for (var i = 0; i < 40; i++) ...[
          claudeUser('msg $i', uuid: 'u$i'),
          claudeAssistant([
            claudeToolUse('t$i', 'Bash', {'command': command}),
          ], uuid: 'a$i'),
        ],
      ].map((l) => '$l\n').join(),
    );
    final bin = await Directory.systemTemp.createTemp('shellherd-agent-');
    addTearDown(() => bin.delete(recursive: true));
    // herdr takes a process with this name for an agent.
    await Link('${bin.path}/claude').create('/usr/bin/cat');

    await openHost(tester, herdr, env: {'CLAUDE_CONFIG_DIR': config.path});
    await tester.tap(find.widgetWithText(NavigationDestination, 'spaces'));
    await tester.pump();
    final snapshot = await herdr.client.snapshot();
    await tester.tap(
      find.text(snapshot.panes.singleWhere((p) => p.id == pane).displayName),
    );
    await untilFound(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), '${bin.path}/claude');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await untilFound(tester, find.text('prompt claude…'));
    await herdr.client.request('pane.report_agent_session', {
      'pane_id': pane,
      'source': 'herdr:claude',
      'agent': 'claude',
      'seq': DateTime.now().microsecondsSinceEpoch * 1000,
      'agent_session_id': 's1',
      'agent_session_path': file.path,
      'session_start_source': 'startup',
    });
    // herdr sends no event for it: the next snapshot refresh, within
    // 15 s, brings it.
    await untilFound(
      tester,
      message('msg 39'),
      within: const Duration(seconds: 40),
    );
    expect(message('msg 0'), findsNothing);

    await scrollUpUntil(tester, message('msg 0'));
    await untilGone(tester, find.text('Loading earlier messages…'));
    expect(find.textContaining('Earlier messages'), findsNothing);
    // Each message once, in order, back down to the newest.
    for (var i = 0; i < 40; i += 3) {
      await scrollUpUntil(tester, message('msg $i'), dy: -150);
      expect(message('msg $i'), findsOneWidget);
    }

    await tester.pumpWidget(const SizedBox()); // closes the connections
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  testWidgets(
    'a wide window shows the sidebar and the pane side by side',
    skip: skip,
    (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final herdr = await HerdrTestSession.start();
      addTearDown(herdr.stop);
      final pane = await herdr.createWorkspace('myspace');
      final dir = await Directory.systemTemp.createTemp('shellherd-agent-');
      addTearDown(() => dir.delete(recursive: true));
      // herdr takes a process with this name for an agent.
      await Link('${dir.path}/claude').create('/usr/bin/cat');
      Finder inSidebar(Finder f) =>
          find.descendant(of: find.byType(HerdrSidebar), matching: f);
      Finder text(String part) => find.textContaining(part, findRichText: true);

      await openHost(tester, herdr);
      await untilFound(tester, inSidebar(find.text('myspace')));
      expect(inSidebar(find.text('No agents are running.')), findsOneWidget);
      expect(find.text('Pick a pane'), findsOneWidget);

      final snapshot = await herdr.client.snapshot();
      final row = snapshot.panes.singleWhere((p) => p.id == pane);
      await tester.tap(inSidebar(find.text(row.displayName)));
      await untilFound(tester, find.byType(TextField));
      expect(find.byType(HerdrSidebar), findsOneWidget);

      Future<void> submit(String input) async {
        await tester.enterText(find.byType(TextField), input);
        await tester.pump();
        await tester.tap(find.byTooltip('Send'));
      }

      await submit(r'echo wide-$((40+2))');
      await untilFound(tester, text('wide-42'));

      // A real agent at work takes a prompt.
      await submit('${dir.path}/claude');
      await untilFound(tester, find.text('prompt claude…'));
      await herdr.client.request('pane.report_agent', {
        'pane_id': pane,
        'source': 'test',
        'agent': 'claude',
        'state': 'working',
      });
      await untilFound(tester, inSidebar(find.text('working')));
      await submit('while-working');
      await untilFound(tester, inPane('while-working'));

      await tester.tap(find.byTooltip('terminal'));
      await untilFound(tester, find.widgetWithText(Chip, 'ssh'));

      await tester.pumpWidget(const SizedBox()); // closes the connections
      await Future<void>.delayed(const Duration(milliseconds: 50));
    },
  );
}