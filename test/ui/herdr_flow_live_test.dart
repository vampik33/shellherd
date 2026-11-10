/// The path a user takes to the herdr lists, against a throwaway sshd on
/// 127.0.0.1 and a real herdr server. Skipped when one of them is missing.
@Tags(['herdr'])
@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/app.dart';
import 'package:shellherd/ssh/host.dart';

import '../support/herdr_test_session.dart';
import '../support/live_widgets.dart';
import '../support/memory_secret_store.dart';
import '../support/test_sshd.dart';

Future<void> main() async {
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  final skip =
      !await HerdrTestSession.herdrAvailable() || TestSshd.binary == null;

  testWidgets('a tap on a host opens its agents and spaces', skip: skip, (
    tester,
  ) async {
    final dir = await Directory.systemTemp.createTemp('shellherd-herdr-');
    addTearDown(() => dir.delete(recursive: true));
    final herdr = await HerdrTestSession.start();
    addTearDown(herdr.stop);
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
    final pane = await herdr.createWorkspace('myspace');
    Finder chip(String label) => find.widgetWithText(Chip, label);
    Finder nav(String label) =>
        find.widgetWithText(NavigationDestination, label);

    await tester.pumpWidget(ShellherdApp(services));
    await untilFound(tester, find.text('testbox'));
    await tester.tap(find.text('testbox'));
    await untilFound(tester, find.text('Trust'));
    await tester.tap(find.text('Trust'));
    await untilFound(tester, chip('live'));
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
}
