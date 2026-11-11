/// The whole path a user takes, against a throwaway sshd on 127.0.0.1 (see
/// test/support/test_sshd.dart): add a host, install its public line, open
/// the terminal. Skipped when sshd is not installed.
@Tags(['sshd'])
@Timeout(Duration(seconds: 60))
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/app.dart';
import 'package:xterm/xterm.dart';

import '../support/live_widgets.dart';
import '../support/memory_secret_store.dart';
import '../support/test_sshd.dart';

void main() {
  LiveTestWidgetsFlutterBinding.ensureInitialized();
  final skip = TestSshd.binary == null ? 'sshd is not installed' : null;

  testWidgets(
    'add a host, install the key, open the terminal',
    skip: skip != null,
    (tester) async {
      final dir = await Directory.systemTemp.createTemp('shellherd-flow-');
      addTearDown(() => dir.delete(recursive: true));
      final sshd = await TestSshd.start();
      addTearDown(sshd.stop);
      final services = AppServices(dataDir: dir, secrets: MemorySecretStore());

      await tester.pumpWidget(ShellherdApp(services));
      await untilFound(tester, find.byTooltip('Add host'));
      await tester.tap(find.byTooltip('Add host'));
      await untilFound(tester, hostField('Label'));
      await tester.enterText(hostField('Label'), 'testbox');
      await tester.enterText(hostField('Address'), '127.0.0.1');
      await tester.enterText(hostField('Port'), '${sshd.port}');
      await tester.enterText(hostField('User'), Platform.environment['USER']!);

      await tester.ensureVisible(find.text('Generate key'));
      await tester.pump();
      await tester.tap(find.text('Generate key'));
      final line = find.textContaining('ssh-ed25519 AAAA');
      await untilFound(tester, line);
      await sshd.authorize(
        tester.widget<SelectableText>(find.byType(SelectableText)).data!,
      );

      await tester.tap(find.text('Save'));
      await untilFound(tester, find.text('testbox'));
      await untilGone(tester, hostField('Label'));

      await tester.tap(find.byTooltip('Terminal on testbox'));
      await untilFound(tester, find.text('Trust'));
      await tester.tap(find.text('Trust'));
      await untilFound(tester, find.widgetWithText(Chip, 'ssh'));

      final terminal = tester
          .widget<TerminalView>(find.byType(TerminalView))
          .terminal;
      terminal.textInput("printf 'flow%s\\n' ok\r");
      await until(
        tester,
        () => terminal.buffer.getText().contains('flowok'),
        'command output',
      );

      await tester.pumpWidget(const SizedBox()); // closes the connection
      await Future<void>.delayed(const Duration(milliseconds: 50));
    },
  );
}
