/// The host list and the host form on real temporary files, with an
/// in-memory key store.
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/app.dart';
import 'package:shellherd/herdr/ui/herdr_screen.dart';
import 'package:shellherd/herdr/ui/pane_screen.dart';
import 'package:shellherd/notify/notifier.dart';
import 'package:shellherd/notify/notify_control.dart';
import 'package:shellherd/ssh/host.dart';
import 'package:shellherd/ssh/known_hosts.dart';

import '../support/live_widgets.dart';
import '../support/memory_secret_store.dart';

/// Records the calls; [allowed] is what sync answers.
class _FakeNotify implements NotifyControl {
  final syncs = <bool>[];
  final panes = <(PaneTarget, bool)>[];
  var allowed = true;

  @override
  Future<bool> sync({bool ask = false}) async {
    syncs.add(ask);
    return allowed;
  }

  @override
  void paneShown(PaneTarget pane, bool shown) => panes.add((pane, shown));
}

void main() {
  LiveTestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late _ControlledSecrets secrets;
  late AppServices services;
  late _FakeNotify notify;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('shellherd-ui-');
    secrets = _ControlledSecrets();
    services = AppServices(dataDir: dir, secrets: secrets);
    notify = _FakeNotify();
    services.notify = notify;
  });
  tearDown(() => dir.delete(recursive: true));

  const trusted = HostKey('ssh-ed25519', 'SHA256:the-server');

  /// Saves a host with a real generated key.
  Future<Host> savedHost({
    String id = 'h1',
    String address = 'pc.example',
    int port = 22,
    String? herdrSession,
    bool mosh = false,
  }) async {
    final host = Host(
      id: id,
      label: 'label-$id',
      address: address,
      port: port,
      user: 'dev',
      keyId: await services.keys.generate(),
      herdrSession: herdrSession,
      mosh: mosh,
    );
    await services.hosts.save(host);
    return host;
  }

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(ShellherdApp(services));
    await until(
      tester,
      () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      'loaded list',
    );
  }

  Future<void> tapOn(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await tester.pump();
  }

  Future<void> tapText(WidgetTester tester, String text) =>
      tapOn(tester, find.text(text).last);

  Future<void> openAddForm(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Add host'));
    await untilFound(tester, hostField('Label'));
  }

  Future<void> fillForm(WidgetTester tester, {String port = '22'}) async {
    await tester.enterText(hostField('Label'), ' workbox ');
    await tester.enterText(hostField('Address'), 'pc.example');
    await tester.enterText(hostField('Port'), port);
    await tester.enterText(hostField('User'), 'dev');
    await tester.pump();
  }

  Finder publicLine() => find.textContaining('ssh-ed25519 AAAA');

  Future<void> openEdit(WidgetTester tester, Host host) async {
    await tester.tap(find.byTooltip('Edit ${host.label}'));
    await untilFound(tester, publicLine());
  }

  String pemOf(String id) => secrets.values['ssh-key.$id']!;

  testWidgets('adds a host: a key is required, and the line is shown', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(find.text('No hosts yet. Add your PC.'), findsOneWidget);

    await openAddForm(tester);
    await fillForm(tester, port: '2222');
    await tapText(tester, 'Save');
    await untilFound(tester, find.text('Generate or import a key first.'));
    expect(await services.hosts.list(), isEmpty);

    await tapText(tester, 'Generate key');
    await untilFound(tester, publicLine());
    expect(find.text('Generate or import a key first.'), findsNothing);
    await tapText(tester, 'Save');
    await untilFound(tester, find.text('dev@pc.example:2222'));
    await untilGone(tester, hostField('Label'));
    expect(find.text('workbox'), findsOneWidget, reason: 'trimmed');

    final saved = (await services.hosts.list()).single;
    expect(saved.port, 2222);
    expect(await services.keys.identities(saved.keyId!), hasLength(1));
    expect(await services.keys.ids(), [saved.keyId]);
  });

  testWidgets('rejects empty fields and a bad port', (tester) async {
    await pumpApp(tester);
    await openAddForm(tester);
    await tester.enterText(hostField('Port'), '70000');
    await tapText(tester, 'Save');
    await untilFound(tester, find.text('1 to 65535'));
    expect(find.text('Required'), findsNWidgets(3));
    expect(await services.hosts.list(), isEmpty);
  });

  testWidgets('leaving the form deletes a key made in it', (tester) async {
    await pumpApp(tester);
    await openAddForm(tester);
    await tapText(tester, 'Generate key');
    await untilFound(tester, publicLine());
    expect(await services.keys.ids(), hasLength(1));

    await tester.tap(find.byType(BackButton));
    await untilGone(tester, hostField('Label'));
    await until(
      tester,
      () => secrets.values.isEmpty,
      'the unsaved key to be deleted',
    );
    expect(await services.hosts.list(), isEmpty);
  });

  testWidgets('a second generate replaces the unsaved key', (tester) async {
    await pumpApp(tester);
    await openAddForm(tester);
    await tapText(tester, 'Generate key');
    await untilFound(tester, publicLine());
    final first = (await services.keys.ids()).single;

    await tapText(tester, 'Generate key');
    await untilFound(tester, find.text('Replace'));
    await tapText(tester, 'Replace');
    await until(
      tester,
      () =>
          secrets.values.length == 1 &&
          !secrets.values.containsKey('ssh-key.$first'),
      'the first key to be replaced',
    );
  });

  testWidgets('an edit keeps the fields the form does not show', (
    tester,
  ) async {
    final host = await savedHost(herdrSession: 'main', mosh: true);
    await pumpApp(tester);
    await openEdit(tester, host);
    await tester.enterText(hostField('Label'), 'renamed');
    await tapText(tester, 'Save');
    await untilFound(tester, find.text('renamed'));

    final saved = (await services.hosts.list()).single;
    expect(saved.id, host.id);
    expect(saved.keyId, host.keyId);
    expect(saved.herdrSession, 'main');
    expect(saved.mosh, isTrue);
  });

  testWidgets('mosh: the switch shows the server command, and the list a '
      'mosh button', (tester) async {
    final host = await savedHost();
    await pumpApp(tester);
    expect(find.byTooltip('Mosh terminal on ${host.label}'), findsNothing);
    await openEdit(tester, host);
    expect(hostField('mosh-server command'), findsNothing);
    final moshSwitch = find.widgetWithText(SwitchListTile, 'Mosh');
    await tester.ensureVisible(moshSwitch);
    await tester.tap(moshSwitch);
    await tester.pump();
    await tester.enterText(hostField('mosh-server command'), ' ~/bin/mosh-server ');
    await tapText(tester, 'Save');
    await untilGone(tester, hostField('Label'));
    final saved = (await services.hosts.list()).single;
    expect(saved.mosh, isTrue);
    expect(saved.moshServer, '~/bin/mosh-server');
    await untilFound(tester, find.byTooltip('Mosh terminal on ${host.label}'));
  });

  testWidgets('mosh: an empty server command is the default', (tester) async {
    final host = await savedHost(mosh: true);
    await pumpApp(tester);
    await openEdit(tester, host);
    await tester.enterText(hostField('mosh-server command'), '  ');
    await tapText(tester, 'Save');
    await untilGone(tester, hostField('Label'));
    expect((await services.hosts.list()).single.moshServer, 'mosh-server');
  });

  group('notify', () {
    Finder notifySwitch() => find.widgetWithText(SwitchListTile, 'Notify');

    Future<void> saveWithNotifyOn(WidgetTester tester, Host host) async {
      await openEdit(tester, host);
      await tester.ensureVisible(notifySwitch());
      await tester.tap(notifySwitch());
      await tester.pump();
      await tapText(tester, 'Save');
    }

    testWidgets('is off for a new host', (tester) async {
      await pumpApp(tester);
      await openAddForm(tester);
      expect(tester.widget<SwitchListTile>(notifySwitch()).value, isFalse);
      await fillForm(tester);
      await tapText(tester, 'Generate key');
      await untilFound(tester, publicLine());
      await tapText(tester, 'Save');
      await untilGone(tester, hostField('Label'));
      expect((await services.hosts.list()).single.notify, isFalse);
      expect(notify.syncs, [false], reason: 'no permission prompt');
    });

    testWidgets('on saves it, and asks to allow notifications', (
      tester,
    ) async {
      final host = await savedHost();
      await pumpApp(tester);
      await saveWithNotifyOn(tester, host);
      await untilGone(tester, hostField('Label'));
      expect((await services.hosts.list()).single.notify, isTrue);
      expect(notify.syncs, [true]);
    });

    testWidgets('says so when the system does not allow notifications', (
      tester,
    ) async {
      final host = await savedHost();
      notify.allowed = false;
      await pumpApp(tester);
      await saveWithNotifyOn(tester, host);
      await untilFound(
        tester,
        find.text(
          'Notifications are off for shellherd in the system settings.',
        ),
      );
      expect((await services.hosts.list()).single.notify, isTrue);
    });

    testWidgets('a tapped notification opens its pane over the screens open '
        'now', (tester) async {
      // Port 1 refuses at once: the screens show no link.
      final host = await savedHost(address: '127.0.0.1', port: 1);
      await pumpApp(tester);
      await openEdit(tester, host);
      unawaited(services.openPane(PaneTarget(host.id, 'w1:p2')));
      await untilFound(tester, find.byType(PaneScreen));
      expect(hostField('Label'), findsNothing, reason: 'the form is gone');
      expect(
        tester.widget<PaneScreen>(find.byType(PaneScreen)).paneId,
        'w1:p2',
      );
      expect(notify.panes, [(PaneTarget(host.id, 'w1:p2'), true)]);
      await tester.pageBack();
      await untilGone(tester, find.byType(PaneScreen));
      expect(find.byType(HerdrScreen), findsOneWidget);
      expect(notify.panes.last, (PaneTarget(host.id, 'w1:p2'), false));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a newly trusted server key updates the watchers', (
      tester,
    ) async {
      final host = await savedHost();
      services.connector.onTrusted!(host);
      await tester.pump();
      expect(notify.syncs, [false], reason: 'no permission prompt');
    });

    testWidgets('a notification of a removed host opens nothing', (
      tester,
    ) async {
      await pumpApp(tester);
      await services.openPane(const PaneTarget('gone', 'w1:p1'));
      await tester.pump();
      expect(find.byType(HerdrScreen), findsNothing);
    });
  });

  testWidgets('Save deletes the key that a new one replaced', (tester) async {
    final host = await savedHost();
    await pumpApp(tester);
    await openEdit(tester, host);
    await tapText(tester, 'Generate key');
    await untilFound(tester, find.text('Replace'));
    await tapText(tester, 'Replace');
    await until(tester, () => secrets.values.length == 2, 'the new key');
    await until(
      tester,
      () => find.text('Replace').evaluate().isEmpty,
      'the dialog to close',
    );
    await tapText(tester, 'Save');
    await untilGone(tester, hostField('Label'));

    final saved = (await services.hosts.list()).single;
    expect(saved.keyId, isNot(host.keyId));
    await until(tester, () => secrets.values.length == 1, 'the old key gone');
    expect(await services.keys.ids(), [saved.keyId]);
  });

  testWidgets('leaving an edit keeps the old key and drops the new one', (
    tester,
  ) async {
    final host = await savedHost();
    await pumpApp(tester);
    await openEdit(tester, host);
    await tapText(tester, 'Generate key');
    await tapText(tester, 'Replace');
    await until(tester, () => secrets.values.length == 2, 'the new key');
    await untilGone(tester, find.text('Replace'));

    await tester.tap(find.byType(BackButton));
    await untilGone(tester, hostField('Label'));
    await until(tester, () => secrets.values.length == 1, 'the new key gone');
    expect(await services.keys.ids(), [host.keyId]);
    expect((await services.hosts.list()).single.keyId, host.keyId);
  });

  Finder button(String text) => find.widgetWithText(OutlinedButton, text);
  bool enabled(WidgetTester tester, String text) =>
      tester.widget<OutlinedButton>(button(text)).onPressed != null;
  Finder saveButton() => find.widgetWithText(TextButton, 'Save');

  testWidgets('no action runs until the saved key has loaded', (tester) async {
    final host = await savedHost();
    final gate = secrets.readGate = Completer<void>();
    await pumpApp(tester);
    await tester.tap(find.byTooltip('Edit ${host.label}'));
    await untilFound(tester, button('Generate key'));

    expect(enabled(tester, 'Generate key'), isFalse);
    expect(enabled(tester, 'Import key'), isFalse);
    expect(tester.widget<TextButton>(saveButton()).onPressed, isNull);
    expect(
      tester
          .widget<IconButton>(
            find.widgetWithIcon(IconButton, Icons.delete_outline),
          )
          .onPressed,
      isNull,
    );

    secrets.readGate = null;
    gate.complete();
    await untilFound(tester, publicLine());
    await tester.pump();
    expect(enabled(tester, 'Generate key'), isTrue);
    expect(tester.widget<TextButton>(saveButton()).onPressed, isNotNull);
  });

  testWidgets('the form can be left while the saved key loads', (tester) async {
    final host = await savedHost();
    final gate = secrets.readGate = Completer<void>();
    await pumpApp(tester);
    await tester.tap(find.byTooltip('Edit ${host.label}'));
    await untilFound(tester, button('Generate key'));
    await tester.tap(find.byType(BackButton));
    await untilGone(tester, hostField('Label'));
    secrets.readGate = null;
    gate.complete();
    expect(await services.keys.ids(), [host.keyId]);
  });

  testWidgets('a failed read of a new key deletes both unsaved keys on leave', (
    tester,
  ) async {
    await pumpApp(tester);
    await openAddForm(tester);
    await tapText(tester, 'Generate key');
    await untilFound(tester, publicLine());
    final firstLine = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .data;

    secrets.failReads = true;
    await tapText(tester, 'Generate key');
    await untilFound(tester, find.text('Replace'));
    await tapText(tester, 'Replace');
    await untilFound(tester, find.textContaining('Cannot store the key'));
    secrets.failReads = false;
    expect(secrets.values, hasLength(2));
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).data,
      firstLine,
      reason: 'the first key stays selected',
    );

    await tester.tap(find.byType(BackButton));
    await untilGone(tester, hostField('Label'));
    await until(tester, () => secrets.values.isEmpty, 'both keys deleted');
  });

  testWidgets('a failed delete of the old unsaved key is retried at the end', (
    tester,
  ) async {
    await pumpApp(tester);
    await openAddForm(tester);
    await fillForm(tester);
    await tapText(tester, 'Generate key');
    await untilFound(tester, publicLine());

    secrets.failDeletes = true;
    await tapText(tester, 'Generate key');
    await untilFound(tester, find.text('Replace'));
    await tapText(tester, 'Replace');
    await untilFound(tester, find.textContaining('Cannot store the key'));
    secrets.failDeletes = false;
    expect(secrets.values, hasLength(2));

    await tapText(tester, 'Save');
    await untilGone(tester, hostField('Label'));
    await until(tester, () => secrets.values.length == 1, 'the old key gone');
    final saved = (await services.hosts.list()).single;
    expect(await services.keys.ids(), [saved.keyId]);
  });

  group('import', () {
    Future<void> openImport(WidgetTester tester) async {
      await tapText(tester, 'Import key');
      await untilFound(tester, find.text('Private key (PEM text)'));
    }

    Finder pemField() =>
        find.widgetWithText(TextField, 'Private key (PEM text)');

    testWidgets('a bad text shows a message that does not quote it', (
      tester,
    ) async {
      await pumpApp(tester);
      await openAddForm(tester);
      await openImport(tester);
      await tester.enterText(pemField(), 'not-a-key-SENSITIVE');
      await tapText(tester, 'Import');
      await untilFound(
        tester,
        find.text('This is not a private key, or the passphrase is wrong.'),
      );
      expect(await services.keys.ids(), isEmpty);
    });

    testWidgets('a pasted key is used, with surrounding space removed', (
      tester,
    ) async {
      final id = await services.keys.generate();
      final pem = pemOf(id);
      final line = await services.keys.publicLine(id);
      await services.keys.delete(id);

      await pumpApp(tester);
      await openAddForm(tester);
      await openImport(tester);
      await tester.enterText(pemField(), '\n  $pem  \n');
      await tapText(tester, 'Import');
      await untilFound(tester, find.text(line));
      expect(await services.keys.ids(), hasLength(1));
    });
  });

  testWidgets('Copy puts the public line on the clipboard', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final host = await savedHost();
    await pumpApp(tester);
    await openEdit(tester, host);
    await tapText(tester, 'Copy');
    await untilFound(tester, find.text('Public line copied.'));
    expect(copied, [await services.keys.publicLine(host.keyId!)]);
  });

  testWidgets('a host whose key is missing says so and can get a new one', (
    tester,
  ) async {
    final host = await savedHost();
    await services.keys.delete(host.keyId!);
    await pumpApp(tester);
    await tester.tap(find.byTooltip('Edit ${host.label}'));
    await untilFound(
      tester,
      find.text('The saved key is missing. Make a new one.'),
    );
    await tapText(tester, 'Generate key');
    await untilFound(tester, publicLine());
    expect(find.text('Replace'), findsNothing, reason: 'nothing to replace');
  });

  group('remove', () {
    Future<void> remove(WidgetTester tester, Host host) async {
      await openEdit(tester, host);
      await tester.tap(find.byTooltip('Remove host'));
      await untilFound(tester, find.text('Remove'));
      await tapText(tester, 'Remove');
      await untilGone(tester, hostField('Label'));
    }

    testWidgets('deletes the host, its key and the trusted server key', (
      tester,
    ) async {
      final host = await savedHost();
      await services.knownHosts.trust(host.address, 22, trusted);
      await pumpApp(tester);
      await remove(tester, host);
      await untilFound(tester, find.text('No hosts yet. Add your PC.'));
      expect(await services.hosts.list(), isEmpty);
      expect(await services.keys.ids(), isEmpty);
      expect(await services.knownHosts.lookup(host.address, 22), isNull);
      expect(notify.syncs, [false], reason: 'its watcher stops');
    });

    testWidgets('keeps the trusted key while another host uses the address', (
      tester,
    ) async {
      final host = await savedHost();
      final other = await savedHost(id: 'h2', address: 'PC.example');
      await services.knownHosts.trust(host.address, 22, trusted);
      await pumpApp(tester);
      await remove(tester, host);
      await untilGone(tester, find.text(host.label));
      expect(await services.knownHosts.lookup(host.address, 22), trusted);
      expect(await services.keys.ids(), [other.keyId]);
    });

    testWidgets('Cancel removes nothing', (tester) async {
      final host = await savedHost();
      await pumpApp(tester);
      await openEdit(tester, host);
      await tester.tap(find.byTooltip('Remove host'));
      await untilFound(tester, find.text('Remove'));
      await tapText(tester, 'Cancel');
      await untilGone(tester, find.text('Remove'));
      expect(await services.hosts.list(), hasLength(1));
      expect(await services.keys.ids(), [host.keyId]);
    });
  });

  group('password login', () {
    const kept = 'Saved. Leave empty to keep it.';

    Future<Host> savedPasswordHost({String password = 'old pw'}) async {
      final host = Host(
        id: 'p1',
        label: 'label-p1',
        address: 'pc.example',
        user: 'dev',
        auth: SshAuth.password,
      );
      await services.keys.savePassword(host.id, password);
      await services.hosts.save(host);
      return host;
    }

    Future<void> choose(WidgetTester tester, String login) => tapOn(
      tester,
      find.descendant(
        of: find.byType(SegmentedButton<SshAuth>),
        matching: find.text(login),
      ),
    );

    Future<void> openPasswordEdit(WidgetTester tester, Host host) async {
      await tester.tap(find.byTooltip('Edit ${host.label}'));
      await untilFound(tester, find.text(kept));
    }

    testWidgets('a new host: the password goes to the keystore only', (
      tester,
    ) async {
      await pumpApp(tester);
      await openAddForm(tester);
      await fillForm(tester);
      await choose(tester, 'Password');
      expect(find.text('Generate key'), findsNothing);
      await tapText(tester, 'Save');
      await untilFound(tester, find.text('Required'));
      expect(await services.hosts.list(), isEmpty);

      await tester.enterText(hostField('Password'), 'hunter 2');
      await tapText(tester, 'Save');
      await untilGone(tester, hostField('Label'));

      final saved = (await services.hosts.list()).single;
      expect(saved.auth, SshAuth.password);
      expect(saved.keyId, isNull);
      expect(await services.keys.password(saved.id), 'hunter 2');
      expect(await services.keys.ids(), isEmpty);
      final file = File('${dir.path}/hosts.json').readAsStringSync();
      expect(file, isNot(contains('hunter')));
    });

    testWidgets('an edit keeps the saved password, or takes a new one', (
      tester,
    ) async {
      final host = await savedPasswordHost();
      await pumpApp(tester);
      await openPasswordEdit(tester, host);
      await tester.enterText(hostField('Label'), 'renamed');
      await tapText(tester, 'Save');
      await untilGone(tester, hostField('Label'));
      expect(await services.keys.password(host.id), 'old pw');

      await tester.tap(find.byTooltip('Edit renamed'));
      await untilFound(tester, find.text(kept));
      await tester.enterText(hostField('Password'), 'new pw');
      await tapText(tester, 'Save');
      await untilGone(tester, hostField('Label'));
      expect(await services.keys.password(host.id), 'new pw');
    });

    testWidgets('a failed save keeps the old host and its password', (
      tester,
    ) async {
      final host = await savedPasswordHost();
      await pumpApp(tester);
      await openPasswordEdit(tester, host);
      await tester.enterText(hostField('Address'), 'new.example');
      await tester.enterText(hostField('Password'), 'new pw');
      // The write of hosts.json goes through this path, which is now taken.
      await Directory('${dir.path}/hosts.json.tmp').create();
      await tapText(tester, 'Save');
      await untilFound(tester, find.textContaining('Cannot save the host'));
      expect((await services.hosts.list()).single.address, 'pc.example');
      expect(await services.keys.password(host.id), 'old pw');
    });

    testWidgets('a failed save of a new host leaves no password', (
      tester,
    ) async {
      await pumpApp(tester);
      await openAddForm(tester);
      await fillForm(tester);
      await choose(tester, 'Password');
      await tester.enterText(hostField('Password'), 'pw');
      await Directory('${dir.path}/hosts.json.tmp').create();
      await tapText(tester, 'Save');
      await untilFound(tester, find.textContaining('Cannot save the host'));
      expect(secrets.values, isEmpty);
    });

    testWidgets('a missing saved password has to be typed again', (
      tester,
    ) async {
      final host = await savedPasswordHost();
      await services.keys.deletePassword(host.id);
      await pumpApp(tester);
      await tester.tap(find.byTooltip('Edit ${host.label}'));
      await untilFound(tester, hostField('Password'));
      expect(find.text(kept), findsNothing);
      await tapText(tester, 'Save');
      await untilFound(tester, find.text('Required'));
    });

    testWidgets('a key host that moves to a password loses its key', (
      tester,
    ) async {
      final host = await savedHost();
      await pumpApp(tester);
      await openEdit(tester, host);
      await choose(tester, 'Password');
      await tester.enterText(hostField('Password'), 'pw');
      await tapText(tester, 'Save');
      await untilGone(tester, hostField('Label'));
      final saved = (await services.hosts.list()).single;
      expect(saved.auth, SshAuth.password);
      expect(await services.keys.ids(), isEmpty);
      expect(await services.keys.password(host.id), 'pw');
    });

    testWidgets('a password host that moves to a key loses its password', (
      tester,
    ) async {
      final host = await savedPasswordHost();
      await pumpApp(tester);
      await openPasswordEdit(tester, host);
      await choose(tester, 'SSH key');
      await tapText(tester, 'Save');
      await untilFound(tester, find.text('Generate or import a key first.'));
      await tapText(tester, 'Generate key');
      await untilFound(tester, publicLine());
      await tapText(tester, 'Save');
      await untilGone(tester, hostField('Label'));
      final saved = (await services.hosts.list()).single;
      expect(saved.auth, SshAuth.key);
      expect(await services.keys.ids(), [saved.keyId]);
      expect(await services.keys.password(host.id), isNull);
    });

    testWidgets('removing the host deletes its password', (tester) async {
      final host = await savedPasswordHost();
      await pumpApp(tester);
      await openPasswordEdit(tester, host);
      await tester.tap(find.byTooltip('Remove host'));
      await untilFound(tester, find.text('Remove'));
      await tapText(tester, 'Remove');
      await untilFound(tester, find.text('No hosts yet. Add your PC.'));
      expect(secrets.values, isEmpty);
    });
  });

  testWidgets('Forget removes the trusted server key after a confirm', (
    tester,
  ) async {
    final host = await savedHost();
    await services.knownHosts.trust(host.address, 22, trusted);
    await pumpApp(tester);
    await openEdit(tester, host);
    await untilFound(tester, find.textContaining(trusted.fingerprint));

    await tapText(tester, 'Forget server key');
    await untilFound(tester, find.text('Forget'));
    await tapText(tester, 'Forget');
    await untilGone(tester, find.text('Forget server key'));
    expect(await services.knownHosts.lookup(host.address, 22), isNull);
  });

  testWidgets('Save checks a field that is scrolled out of view', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await pumpApp(tester);
    await openAddForm(tester);
    await tapText(tester, 'Generate key'); // scrolls to the bottom
    await untilFound(tester, publicLine());
    await tester.ensureVisible(find.text('Import key'));
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pump();
    await until(
      tester,
      () => find.text('Required', skipOffstage: false).evaluate().length == 3,
      'the three empty fields to be flagged',
    );
    expect(await services.hosts.list(), isEmpty);
  });

  testWidgets('a damaged hosts file is an error, with no way to overwrite', (
    tester,
  ) async {
    await File('${dir.path}/hosts.json').writeAsString('{not json');
    await pumpApp(tester);
    await untilFound(
      tester,
      find.textContaining('Cannot read the saved hosts'),
    );
    await untilGone(tester, find.byTooltip('Add host'));
  });
}

/// An in-memory store whose reads can wait or fail, and whose deletes can
/// fail.
class _ControlledSecrets extends MemorySecretStore {
  Completer<void>? readGate;
  bool failReads = false;
  bool failDeletes = false;

  @override
  Future<String?> read(String key) async {
    await readGate?.future;
    if (failReads) throw StateError('read failed');
    return super.read(key);
  }

  @override
  Future<void> delete(String key) async {
    if (failDeletes) throw StateError('delete failed');
    await super.delete(key);
  }
}
