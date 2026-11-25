import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../herdr/api/herdr_client.dart';
import '../ssh/host.dart';
import 'agent_watcher.dart';

/// Shows and takes back the notification of one agent.
abstract interface class Notifier {
  Future<void> show(Host host, AgentAlert alert);
  Future<void> cancel(String hostId, String paneId);
}

/// The pane that a notification opens.
class PaneTarget {
  const PaneTarget(this.hostId, this.paneId);

  final String hostId;
  final String paneId;

  String encode() => jsonEncode([hostId, paneId]);

  /// Null for a payload that is not a [PaneTarget].
  static PaneTarget? decode(String? payload) {
    if (payload == null) return null;
    try {
      if (jsonDecode(payload) case [final String hostId, final String paneId]) {
        return PaneTarget(hostId, paneId);
      }
    } on FormatException {
      // Not ours.
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is PaneTarget && other.hostId == hostId && other.paneId == paneId;

  @override
  int get hashCode => Object.hash(hostId, paneId);
}

/// The id of the notification of one pane. It must be the same in every
/// isolate and run, which [String.hashCode] does not promise: FNV-1a, 31
/// bits, never [reservedNotificationId].
int notificationId(String hostId, String paneId) {
  var h = 0x811c9dc5;
  for (final unit in utf8.encode('$hostId/$paneId')) {
    h = ((h ^ unit) * 0x01000193) & 0xffffffff;
  }
  final id = h & 0x7fffffff;
  return id == reservedNotificationId ? id ^ 1 : id;
}

/// The id of the permanent notification of the background service.
const reservedNotificationId = 1;

/// The text of the notification of [alert].
({String title, String body}) alertText(Host host, AgentAlert alert) => (
  title: switch (alert.status) {
    AgentStatus.blocked => '${alert.agent} needs you',
    _ => '${alert.agent} is done',
  },
  body: [host.label, if (alert.where.isNotEmpty) alert.where].join(' · '),
);

const _channelId = 'agents';

/// [Notifier] on the system notifications: Android, or the desktop
/// notification server on Linux.
class LocalNotifier implements Notifier {
  LocalNotifier._(this._plugin, this._linux);

  final FlutterLocalNotificationsPlugin _plugin;

  /// The Linux plugin, when it is the one this host registered. It is called
  /// directly: [_plugin] picks a platform by `defaultTargetPlatform`, so in a
  /// Linux debug build that emulates Android it would send every call to the
  /// Android plugin, which is not there, and drop it.
  final LinuxFlutterLocalNotificationsPlugin? _linux;

  /// Sets the plugin up in this isolate. [onTap] gets the taps on
  /// notifications while the app runs; only the main isolate gets them.
  static Future<LocalNotifier> init({
    void Function(PaneTarget target)? onTap,
  }) async {
    final plugin = FlutterLocalNotificationsPlugin();
    final DidReceiveNotificationResponseCallback? onResponse = onTap == null
        ? null
        : (response) {
            if (PaneTarget.decode(response.payload) case final target?) {
              onTap(target);
            }
          };
    const linuxSettings = LinuxInitializationSettings(
      defaultActionName: 'Open',
    );
    if (FlutterLocalNotificationsPlatform.instance
        case final LinuxFlutterLocalNotificationsPlugin linux) {
      await linux.initialize(
        settings: linuxSettings,
        onDidReceiveNotificationResponse: onResponse,
      );
      return LocalNotifier._(plugin, linux);
    }
    await plugin.initialize(
      settings: const InitializationSettings(
        // Monochrome: Android shows a status bar icon as a white shape.
        android: AndroidInitializationSettings('ic_stat_shellherd'),
        linux: linuxSettings,
      ),
      onDidReceiveNotificationResponse: onResponse,
    );
    return LocalNotifier._(plugin, null);
  }

  /// The pane of the notification that started the app, if one did. Only
  /// Android ([android]) starts the app from a notification; the Linux
  /// plugin has no launch details and throws [UnimplementedError] for them.
  Future<PaneTarget?> launchTarget({required bool android}) async {
    if (!android) return null;
    final details = await _plugin.getNotificationAppLaunchDetails();
    if (details == null || !details.didNotificationLaunchApp) return null;
    return PaneTarget.decode(details.notificationResponse?.payload);
  }

  @override
  Future<void> show(Host host, AgentAlert alert) {
    final text = alertText(host, alert);
    final id = notificationId(host.id, alert.paneId);
    final payload = PaneTarget(host.id, alert.paneId).encode();
    if (_linux case final linux?) {
      return linux.show(
        id: id,
        title: text.title,
        body: text.body,
        payload: payload,
        notificationDetails: agentNotificationDetails.linux,
      );
    }
    return _plugin.show(
      id: id,
      title: text.title,
      body: text.body,
      payload: payload,
      notificationDetails: agentNotificationDetails,
    );
  }

  @override
  Future<void> cancel(String hostId, String paneId) {
    final id = notificationId(hostId, paneId);
    if (_linux case final linux?) return linux.cancel(id: id);
    return _plugin.cancel(id: id);
  }
}

/// How an agent alert shows.
const agentNotificationDetails = NotificationDetails(
  android: AndroidNotificationDetails(
    _channelId,
    'Agents',
    channelDescription: 'An agent needs you or is done.',
    importance: Importance.high,
    priority: Priority.high,
    category: AndroidNotificationCategory.status,
    // A secure lock screen shows that shellherd has a notification, and
    // hides its text (a title can hold code or file names) unless the
    // phone is set to show sensitive content there.
    visibility: NotificationVisibility.private,
  ),
  linux: LinuxNotificationDetails(
    category: LinuxNotificationCategory.imReceived,
  ),
);
