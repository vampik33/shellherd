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
        await notifier.show(host, alert);
        final id = notificationId('h1', 'p2');
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

/// The Linux plugin, recording what it is asked to do.
class _Linux extends LinuxFlutterLocalNotificationsPlugin {
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
  }) async => shown.add((
    id: id,
    title: title,
    body: body,
    payload: payload,
    details: notificationDetails,
  ));

  @override
  Future<void> cancel({required int id}) async => cancelled.add(id);
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
