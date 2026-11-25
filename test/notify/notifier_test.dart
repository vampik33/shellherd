import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/notify/notifier.dart';

void main() {
  test('the lock screen shows that an alert came; the phone decides on its text', () {
    expect(
      agentNotificationDetails.android!.visibility,
      NotificationVisibility.private,
    );
  });

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
