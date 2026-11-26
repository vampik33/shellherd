import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api/herdr_client.dart';
import 'herdr_connection.dart';
import 'pane_poller.dart';
import 'server_api.dart';

/// Tells the server when a person looks at the agent of one pane, so it
/// stops being done on every client, as the Herdr app's labels.md asks.
///
/// It marks while [shown]: when the pane comes on the screen, when a link
/// comes up, and when the agent is done with a turn it has not marked. A
/// turn it marked is not marked again while the pane stays on the screen,
/// so a "mark unread" from another client stays; showing the pane again
/// marks again.
///
/// Each mark waits until the screen shows text that [_poller] read after
/// the mark was due, or that keeps itself current ([current], as the chat
/// does), and marks no later turn than the one seen then: text that cannot
/// be read leaves the agent done.
class SeenMarker {
  SeenMarker(this._connection, this.paneId, this._poller, {this.current}) {
    // The first snapshot of a link comes before its api: follow both.
    _changes = Listenable.merge([
      _connection.state,
      _connection.snapshot,
      _poller.shownRead,
      ?current,
    ])..addListener(_follow);
    _follow();
  }

  final HerdrConnection _connection;
  final String paneId;
  final PanePoller _poller;

  /// True while the screen shows text that follows the pane without
  /// [_poller], such as the chat over a running transcript read: a mark
  /// that is due needs no read then.
  final ValueListenable<bool>? current;
  late final Listenable _changes;

  /// The api and turn of the mark that is due, and the reads started
  /// when it came due: the screen must show a later one.
  (PaneApi?, int?)? _due;
  var _readsBefore = 0;

  var _shown = true;
  var _closed = false;

  /// The api of the last mark: a new link marks again.
  PaneApi? _markedWith;

  /// The turn marked since the pane came on the screen; [_views] counts
  /// the times it came, so a mark from an earlier time is dropped.
  int? _ackedTurn;
  var _views = 0;

  var _marking = false;

  /// A mark asked for while one was on its way.
  var _again = false;

  /// True while a person can see the pane: the app is in front and no
  /// other screen covers it.
  set shown(bool value) {
    if (value == _shown) return;
    _shown = value;
    if (!value) return;
    _views++;
    _markedWith = null;
    _ackedTurn = null;
    _due = null;
    _follow();
  }

  void _follow() {
    if (!_shown || _closed) return;
    final api = _connection.api;
    final pane = _connection.snapshot.value?.pane(paneId);
    final unmarked =
        pane?.status == AgentStatus.done &&
        pane?.turn != null &&
        pane?.turn != _ackedTurn;
    if (api == _markedWith && !unmarked) return;
    final due = (api, pane?.turn);
    if (due != _due) {
      _due = due;
      _readsBefore = _poller.readsStarted;
    }
    final fresh =
        _poller.shownRead.value > _readsBefore || (current?.value ?? false);
    if (!fresh) return;
    unawaited(_mark(upTo: pane?.turn));
  }

  Future<void> _mark({int? upTo}) async {
    final api = _connection.api;
    if (api == null) return;
    if (_marking) {
      _again = true;
      return;
    }
    _marking = true;
    _markedWith = api;
    final views = _views;
    try {
      final turn = await api.markSeen(
        paneId,
        acked: _ackedTurn,
        upTo: upTo,
        looking: () => views == _views && _shown && !_closed,
      );
      if (views == _views) _ackedTurn = turn;
    } catch (e) {
      debugPrint('shellherd: marking $paneId seen failed: $e');
    } finally {
      _marking = false;
    }
    if (_again) {
      _again = false;
      _follow();
    }
  }

  void dispose() {
    _closed = true;
    _changes.removeListener(_follow);
  }
}
