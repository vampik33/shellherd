import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/notify/agent_watcher.dart';
import 'package:shellherd/notify/notifier.dart';
import 'package:shellherd/ssh/host.dart';

void main() {
  test('the lock screen shows that an alert came; the phone decides on its text', () {
    expect(
      agentNotificationDetails.android!.visibility,
      NotificationVisibility.private,
    );
  });

  // The plugin's own facade picks a platform by defaultTargetPlatform: in a
  // Linux debug build that emulates Android it would drop every call.
  for (final emulated in [TargetPlatform.linux, TargetPlatform.android]) {
    group('on Linux, with ${emulated.name} as the target platform', () {
      late _Linux linux;
      final taps = <PaneTarget>[];
      final host = Host(
        id: 'h1',
        label: 'box',
        address: 'box',
        user: 'me',
        keyId: 'k1',
      );
      const alert = AgentAlert(
        paneId: 'p2',
        status: AgentStatus.blocked,
        agent: 'claude',
        where: 'repo',
      );
      final id = notificationId('h1', 'p2');

      setUp(() {
        debugDefaultTargetPlatformOverride = emulated;
        FlutterLocalNotificationsPlatform.instance = linux = _Linux();
        taps.clear();
      });
      tearDown(() => debugDefaultTargetPlatformOverride = null);

      test('sets the Linux plugin up and passes on taps', () async {
        await LocalNotifier.init(onTap: taps.add);
        expect(linux.settings?.defaultActionName, 'Open');
        linux.onResponse!(
          NotificationResponse(
            notificationResponseType:
                NotificationResponseType.selectedNotification,
            payload: const PaneTarget('h1', 'p2').encode(),
          ),
        );
        expect(taps, [const PaneTarget('h1', 'p2')]);
      });

      test('shows and cancels alerts on the Linux plugin', () async {
        final notifier = await LocalNotifier.init();
        await notifier.show(host, alert);
        expect(linux.shown, [
          (
            id: id,
            title: 'claude needs you',
            body: 'box · repo',
            payload: const PaneTarget('h1', 'p2').encode(),
            details: agentNotificationDetails.linux,
          ),
        ]);
        await notifier.cancel('h1', 'p2');
        expect(linux.cancelled, [id]);
      });

      // The plugin learns the id only when the desktop answers the show.
      test('a cancel waits for the show of its alert', () async {
        final notifier = await LocalNotifier.init();
        final answer = linux.showAnswer = Completer();
        final showing = notifier.show(host, alert);
        final cancelling = notifier.cancel('h1', 'p2');
        await pumpEventQueue();
        expect(linux.cancelled, isEmpty);
        answer.complete();
        await Future.wait([showing, cancelling]);
        expect(linux.cancelled, [id]);
        expect(linux.visible, isEmpty);
      });

      test('a failed show fails, and the cancel still runs', () async {
        final notifier = await LocalNotifier.init();
        final answer = linux.showAnswer = Completer();
        final showing = notifier.show(host, alert);
        final cancelling = notifier.cancel('h1', 'p2');
        answer.completeError(StateError('no notification server'));
        await expectLater(showing, throwsStateError);
        await cancelling;
        expect(linux.cancelled, [id]);
      });

      group('with the desktop late', () {
        Future<LocalNotifier> init() =>
            LocalNotifier.init(linuxDeadline: Duration.zero);

        test('a show it never answers does not hold up the pane', () async {
          final notifier = await init();
          linux.showAnswer = Completer();
          unawaited(notifier.show(host, alert));
          await notifier.cancel('h1', 'p2');
          await notifier.show(host, alert);
          expect(linux.cancelled, [id]);
          expect(linux.shown, hasLength(2));
          expect(linux.visible, {id});
        });

        test('a show it answers after a cancel ran is closed again', () async {
          final notifier = await init();
          final answer = linux.showAnswer = Completer();
          final showing = notifier.show(host, alert);
          await notifier.cancel('h1', 'p2');
          expect(linux.cancelled, [id]);
          answer.complete();
          await showing;
          expect(linux.cancelled, [id, id]);
          expect(linux.visible, isEmpty);
        });

        test('a show it answers late stays when a show came last', () async {
          final notifier = await init();
          final answer = linux.showAnswer = Completer();
          final showing = notifier.show(host, alert);
          await notifier.cancel('h1', 'p2');
          await notifier.show(host, alert);
          answer.complete();
          await showing;
          expect(linux.cancelled, [id]);
          expect(linux.visible, {id});
        });

        test('a show that fails late is not closed again', () async {
          final notifier = await init();
          final answer = linux.showAnswer = Completer();
          final showing = notifier.show(host, alert);
          await notifier.cancel('h1', 'p2');
          answer.completeError(StateError('no notification server'));
          await expectLater(showing, throwsStateError);
          expect(linux.cancelled, [id]);
        });

        // The late cancel's cleanup must not drop the queue of a later show.
        test('a cancel answered late leaves a newer show in order', () async {
          final notifier = await init();
          final cancelAnswer = linux.cancelAnswer = Completer();
          final cancelling = notifier.cancel('h1', 'p2');
          await notifier.cancel('h1', 'p2');
          final answer = linux.showAnswer = Completer();
          final showing = notifier.show(host, alert);
          await pumpEventQueue();
          cancelAnswer.complete();
          await cancelling;
          await notifier.cancel('h1', 'p2');
          answer.complete();
          await showing;
          expect(linux.visible, isEmpty);
        });
      });

      test('the alert of another pane does not wait', () async {
        final notifier = await LocalNotifier.init();
        final answer = linux.showAnswer = Completer();
        final showing = notifier.show(host, alert);
        await notifier.cancel('h1', 'p3');
        expect(linux.cancelled, [notificationId('h1', 'p3')]);
        answer.complete();
        await showing;
        expect(linux.visible, {id});
      });
    });
  }

  group('launchTarget', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('is null on Linux, whose plugin has no launch details', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      FlutterLocalNotificationsPlatform.instance = _NoLaunchDetails();
      final notifier = await LocalNotifier.init();
      expect(await notifier.launchTarget(android: false), isNull);
    });

    test('is null off Android, even if a debug build emulates Android', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      FlutterLocalNotificationsPlatform.instance = _AndroidLaunch(
        _launched(const PaneTarget('h1', 'p2').encode()),
      );
      final notifier = await LocalNotifier.init();
      expect(await notifier.launchTarget(android: false), isNull);
    });

    for (final (what, details, want) in [
      ('the pane of the tapped notification', _launched(const PaneTarget('h1', 'p2').encode()), const PaneTarget('h1', 'p2')),
      ('null when no notification started the app', const NotificationAppLaunchDetails(false), null),
      ('null for a payload that is not a pane', _launched('not json'), null),
      ('null with no launch details', null, null),
    ]) {
      test('is $what on Android', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        FlutterLocalNotificationsPlatform.instance = _AndroidLaunch(details);
        final notifier = await LocalNotifier.init();
        expect(await notifier.launchTarget(android: true), want);
      });
    }
  });
}

NotificationAppLaunchDetails _launched(String payload) =>
    NotificationAppLaunchDetails(
      true,
      notificationResponse: NotificationResponse(
        notificationResponseType: NotificationResponseType.selectedNotification,
        payload: payload,
      ),
    );

/// The Linux plugin, recording what it is asked to do. Like the real one, it
/// knows a shown id only once the desktop answered: with [showAnswer], the
/// next show waits for it. With [cancelAnswer], the next cancel waits for it.
class _Linux extends LinuxFlutterLocalNotificationsPlugin {
  Completer<void>? showAnswer;
  Completer<void>? cancelAnswer;
  final visible = <int>{};
  LinuxInitializationSettings? settings;
  DidReceiveNotificationResponseCallback? onResponse;
  final shown =
      <
        ({
          int id,
          String? title,
          String? body,
          String? payload,
          LinuxNotificationDetails? details,
        })
      >[];
  final cancelled = <int>[];

  @override
  Future<bool?> initialize({
    required LinuxInitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
  }) async {
    this.settings = settings;
    onResponse = onDidReceiveNotificationResponse;
    return true;
  }

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    LinuxNotificationDetails? notificationDetails,
    String? payload,
  }) async {
    shown.add((
      id: id,
      title: title,
      body: body,
      payload: payload,
      details: notificationDetails,
    ));
    final answer = showAnswer;
    showAnswer = null;
    await answer?.future;
    visible.add(id);
  }

  @override
  Future<void> cancel({required int id}) async {
    final answer = cancelAnswer;
    cancelAnswer = null;
    await answer?.future;
    cancelled.add(id);
    visible.remove(id);
  }
}

/// A platform with the interface's defaults, as the Linux plugin has for
/// launch details: they throw [UnimplementedError].
class _NoLaunchDetails extends FlutterLocalNotificationsPlatform {}

class _AndroidLaunch extends AndroidFlutterLocalNotificationsPlugin {
  _AndroidLaunch(this._details);

  final NotificationAppLaunchDetails? _details;

  @override
  Future<bool> initialize({
    required AndroidInitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async => true;

  @override
  Future<NotificationAppLaunchDetails?> getNotificationAppLaunchDetails() async =>
      _details;
}
