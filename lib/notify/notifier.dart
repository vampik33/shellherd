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
  LocalNotifier._(this._plugin, this._linux, this._linuxDeadline);

  final FlutterLocalNotificationsPlugin _plugin;

  /// The Linux plugin, when it is the one this host registered. It is called
  /// directly: [_plugin] picks a platform by `defaultTargetPlatform`, so in a
  /// Linux debug build that emulates Android it would send every call to the
  /// Android plugin, which is not there, and drop it.
  final LinuxFlutterLocalNotificationsPlugin? _linux;

  /// How long one Linux call holds up the next calls of its id.
  final Duration _linuxDeadline;

  /// The Linux calls of each notification id still asked, running or past
  /// their deadline.
  final _linuxQueues = <int, _LinuxQueue>{};

  /// Runs [call], a show if [show], once the earlier Linux calls of [id]
  /// have ended or passed their deadline; a failure still reaches the
  /// caller of its own call.
  ///
  /// The Linux plugin learns a notification's id only when the desktop has
  /// answered its show, so a cancel that overtook the show would find
  /// nothing and leave the alert up: the calls of one id run in order. A
  /// desktop that never answers would then hold up the pane for good, so
  /// each call holds up the next only until its deadline; a show answered
  /// after it is closed again if the last thing asked of its id was a
  /// cancel, which may have run first.
  ///
  /// A show never starts while an earlier show waits for its answer: the
  /// plugin keeps one desktop id per notification, so with two in flight
  /// one alert could not be closed. Only the last call asked of an id runs,
  /// so a show held that way gives way to any later call.
  Future<void> _inOrder(
    int id,
    Future<void> Function() call, {
    required bool show,
  }) async {
    final queue = _linuxQueues.putIfAbsent(id, _LinuxQueue.new);
    queue.lastAsked?.complete();
    final overtaken = queue.lastAsked = Completer<void>();
    queue
      ..wantShown = show
      ..asked += 1;
    final before = queue.last;
    final released = Completer<void>();
    queue.last = released.future;
    void release() {
      if (released.isCompleted) return;
      released.complete();
      queue.asked--;
    }

    var late = false;
    try {
      await before;
      if (queue.inFlight case final earlier? when show) {
        await Future.any([earlier.future, overtaken.future]);
        if (overtaken.isCompleted) return;
      }
      final answered = show ? queue.inFlight = Completer<void>() : null;
      final deadline = Timer(_linuxDeadline, () {
        late = true;
        release();
      });
      try {
        await call();
      } finally {
        deadline.cancel();
        if (answered != null) {
          queue.inFlight = null;
          answered.complete();
        }
      }
    } finally {
      release();
      // A call that ended late may find its queue removed and the id given
      // a newer queue, which is not its to remove.
      if (queue.asked == 0 &&
          queue.inFlight == null &&
          identical(_linuxQueues[id], queue)) {
        _linuxQueues.remove(id);
      }
    }
    if (late && show && !queue.wantShown) {
      await _inOrder(id, show: false, () => _linux!.cancel(id: id));
    }
  }

  /// Sets the plugin up in this isolate. [onTap] gets the taps on
  /// notifications while the app runs; only the main isolate gets them.
  /// [linuxDeadline] is how long one Linux call holds up the next of its id.
  static Future<LocalNotifier> init({
    void Function(PaneTarget target)? onTap,
    Duration linuxDeadline = const Duration(seconds: 5),
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
      return LocalNotifier._(plugin, linux, linuxDeadline);
    }
    await plugin.initialize(
      settings: const InitializationSettings(
        // Monochrome: Android shows a status bar icon as a white shape.
        android: AndroidInitializationSettings('ic_stat_shellherd'),
        linux: linuxSettings,
      ),
      onDidReceiveNotificationResponse: onResponse,
    );
    return LocalNotifier._(plugin, null, linuxDeadline);
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
      return _inOrder(
        id,
        show: true,
        () => linux.show(
          id: id,
          title: text.title,
          body: text.body,
          payload: payload,
          notificationDetails: agentNotificationDetails.linux,
        ),
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
    if (_linux case final linux?) {
      return _inOrder(id, show: false, () => linux.cancel(id: id));
    }
    return _plugin.cancel(id: id);
  }
}

/// The Linux calls of one notification id.
class _LinuxQueue {
  /// Ends when the last call asked has ended or passed its deadline.
  Future<void> last = Future.value();

  /// Completes when the show sent to the desktop has its answer; null when
  /// none waits for one.
  Completer<void>? inFlight;

  /// Completes when a call is asked after the last one.
  Completer<void>? lastAsked;

  /// Whether the last call asked was a show.
  bool wantShown = false;

  /// The calls asked that have neither ended, given way nor passed their
  /// deadline.
  int asked = 0;
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
