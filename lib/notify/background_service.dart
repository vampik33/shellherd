import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:path_provider/path_provider.dart';

import '../app.dart';
import '../ssh/host.dart';
import '../ssh/ids.dart';
import '../ssh/secret_store.dart';
import 'notifier.dart';
import 'notify_control.dart';
import 'one_at_a_time.dart';
import 'watch_hub.dart';

// Messages between the app and the service isolate.
const _reload = 'reload';
const _ready = 'ready';
const _shown = 'shown';

const _title = 'shellherd watches agents';

/// Where the id of the Stop button on the service notification is saved.
/// The id is random, so that only a press of the button stops the
/// watching: before Android 13 any app can send the button's broadcast.
const _stopButtonKey = 'stopButtonId';

Future<String?> _savedStopButtonId() =>
    FlutterForegroundTask.getData<String>(key: _stopButtonKey);

/// Android: the watchers run in a foreground service, in an isolate of
/// their own, so they go on when the app is closed. The service runs while
/// a saved host is [Host.watched], and starts again only with the app.
/// The Stop button on its notification ends it until then.
class ServiceNotify implements NotifyControl {
  ServiceNotify(this._hosts) {
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'watching',
        channelName: 'Watching agents',
        channelDescription: 'Shows that shellherd watches agents.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
      ),
    );
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
  }

  final HostStore _hosts;
  PaneTarget? _target;

  /// Saved as the Stop button id if none is saved yet. One per instance, so
  /// that syncs at the same time save the same id.
  final _newStopButtonId = randomId();

  final _syncs = OneAtATime();

  /// Calls run one after another, so that each reads the hosts and the
  /// service state only after the earlier one started or stopped it.
  @override
  Future<bool> sync({bool ask = false}) => _syncs.run(() => _sync(ask));

  Future<bool> _sync(bool ask) async {
    final (hosts, running) = await (
      _hosts.list(),
      FlutterForegroundTask.isRunningService,
    ).wait;
    final watch = hosts.any((h) => h.watched);
    if (!watch) {
      if (running) _check(await FlutterForegroundTask.stopService());
      return true;
    }
    var permission = await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted && ask) {
      permission = await FlutterForegroundTask.requestNotificationPermission();
    }
    if (running) {
      FlutterForegroundTask.sendDataToTask(_reload);
    } else {
      final stopButton = await _stopButtonId();
      _check(
        await FlutterForegroundTask.startService(
          serviceId: reservedNotificationId,
          serviceTypes: const [ForegroundServiceTypes.specialUse],
          notificationTitle: _title,
          notificationText: '',
          notificationIcon: const NotificationIcon(
            metaDataName: 'io.github.vampik33.shellherd.NOTIFICATION_ICON',
          ),
          notificationButtons: [
            NotificationButton(id: stopButton, text: 'Stop'),
          ],
          callback: startWatchService,
        ),
      );
    }
    // Battery optimization (Doze, and the stricter vendor ones) can stop
    // the service or its network while the phone sleeps. After the start,
    // so that a failed request cannot keep the service from running; a
    // refusal by the user leaves it as it is.
    if (ask) {
      try {
        if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
          await FlutterForegroundTask.requestIgnoreBatteryOptimization();
        }
      } catch (e) {
        debugPrint('shellherd: cannot ask to skip battery optimization: $e');
      }
    }
    return permission == NotificationPermission.granted;
  }

  static void _check(ServiceRequestResult result) {
    if (result case ServiceRequestFailure(:final error)) throw error;
  }

  /// The saved Stop button id, saved first if there is none. It stays the
  /// same from then on, so the button on a notification that the system
  /// builds again after a restart of the service still carries it.
  Future<String> _stopButtonId() async {
    final saved = await _savedStopButtonId();
    if (saved != null) return saved;
    final id = _newStopButtonId;
    if (!await FlutterForegroundTask.saveData(key: _stopButtonKey, value: id)) {
      throw StateError('cannot save the Stop button id');
    }
    return id;
  }

  @override
  void paneShown(PaneTarget pane, bool shown) {
    _target = nextShown(_target, pane, shown);
    _sendShown();
  }

  void _sendShown() =>
      FlutterForegroundTask.sendDataToTask([_shown, _target?.encode()]);

  /// A service that starts asks for the pane on the screen.
  void _onTaskData(Object data) {
    if (data == _ready) _sendShown();
  }
}

/// Runs in the service isolate.
@pragma('vm:entry-point')
void startWatchService() =>
    FlutterForegroundTask.setTaskHandler(_WatchTask());

class _WatchTask extends TaskHandler {
  WatchHub? _hub;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final services = AppServices(
      dataDir: await getApplicationSupportDirectory(),
      secrets: SecureSecretStore(),
    );
    final hub = _hub = WatchHub.ssh(
      services.hosts,
      services.watchConnector,
      await LocalNotifier.init(),
    );
    hub.summary.addListener(
      () => unawaited(
        FlutterForegroundTask.updateService(
          notificationTitle: _title,
          notificationText: hub.summary.value,
        ),
      ),
    );
    await _reloadHosts();
    FlutterForegroundTask.sendDataToMain(_ready);
  }

  Future<void> _reloadHosts() async {
    final hub = _hub;
    if (hub == null) return;
    try {
      await hub.reload();
    } catch (e) {
      debugPrint('shellherd watch: cannot read the hosts: $e');
    }
    // Started again by the system after the last host was turned off.
    if (hub.count == 0) unawaited(FlutterForegroundTask.stopService());
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  void onReceiveData(Object data) {
    switch (data) {
      case _reload:
        unawaited(_reloadHosts());
      case [_shown, final String? target]:
        _hub?.shown = PaneTarget.decode(target);
    }
  }

  /// Stop closes every SSH link of the watchers; [onDestroy] follows.
  @override
  void onNotificationButtonPressed(String id) => unawaited(_pressed(id));

  /// Only the saved Stop button id counts, see [_stopButtonKey].
  Future<void> _pressed(String id) async {
    if (id == await _savedStopButtonId()) {
      await FlutterForegroundTask.stopService();
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _hub?.dispose();
    _hub = null;
  }
}
