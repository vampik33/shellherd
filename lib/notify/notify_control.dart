import 'notifier.dart';
import 'watch_hub.dart';

/// The app's side of the agent notifications.
abstract interface class NotifyControl {
  /// Starts, changes or stops the watching to match the saved hosts. With
  /// [ask] it may ask the user to allow notifications. False if
  /// notifications are not allowed, so none will show.
  Future<bool> sync({bool ask = false});

  /// [pane] came on the screen, or went from it. It does not notify while
  /// it is there.
  void paneShown(PaneTarget pane, bool shown);
}

/// The pane on the screen after [pane] came or went, if [current] was on
/// the screen before. A screen that goes after the next one came does not
/// clear it.
PaneTarget? nextShown(PaneTarget? current, PaneTarget pane, bool shown) =>
    shown ? pane : (current == pane ? null : current);

/// No watching, for tests.
class NoNotify implements NotifyControl {
  const NoNotify();

  @override
  Future<bool> sync({bool ask = false}) async => true;

  @override
  void paneShown(PaneTarget pane, bool shown) {}
}

/// The watchers run in the app itself, while it runs: Linux.
class InProcessNotify implements NotifyControl {
  InProcessNotify(this.hub);

  final WatchHub hub;
  PaneTarget? _target;

  @override
  Future<bool> sync({bool ask = false}) async {
    await hub.reload();
    return true;
  }

  @override
  void paneShown(PaneTarget pane, bool shown) =>
      hub.shown = _target = nextShown(_target, pane, shown);
}
