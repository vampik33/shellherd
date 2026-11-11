/// The path a user takes to the herdr lists, against a throwaway sshd on
/// 127.0.0.1 and a real herdr server. Skipped when one of them is missing.
@Tags(['herdr'])
@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/app.dart';
import 'package:shellherd/herdr/ui/herdr_lists.dart';
import 'package:shellherd/ssh/host.dart';

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
  Future<void> openHost(WidgetTester tester, HerdrTestSession herdr) async {
    final dir = await Directory.systemTemp.createTemp('shellherd-herdr-');
    addTearDown(() => dir.delete(recursive: true));
    final sshd = await TestSshd.start();
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
      await tester.tap(find.text('send'));
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

    await tester.tap(find.byTooltip('Exact screen'));
    await until(
      tester,
      () => find.byType(InteractiveViewer).evaluate().isNotEmpty,
      'the exact screen',
    );
    expect(text('mark-42'), findsWidgets);
    await tester.tap(find.byTooltip('Text view'));
    await tester.pump();

    await submit('${dir.path}/claude');
    await untilFound(tester, find.text('prompt claude…'));
    await submit('hello-agent');
    await untilFound(tester, inPane('hello-agent'));

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
        await tester.tap(find.text('send'));
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
