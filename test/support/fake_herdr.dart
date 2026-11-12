import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:shellherd/herdr/api/herdr_client.dart';
import 'package:shellherd/herdr/herdr_connection.dart';
import 'package:shellherd/herdr/pane_stream.dart';

import 'fake_channel.dart';

/// A herdr server in memory that answers each request by its method.
class FakeHerdr {
  FakeHerdr() {
    dialer.dialed.listen(_serve);
  }

  final dialer = FakeDialer();
  late final client = HerdrClient(
    dialer.call,
    timeout: const Duration(seconds: 2),
  );

  /// When set, the snapshot to serve instead of one built from [panes].
  Map<String, Object?>? snapshotJson;

  /// Pane ids of the next snapshots.
  var panes = ['w1:p1'];

  /// Methods in the order they arrived.
  final methods = <String>[];

  /// Open and finished subscriptions, oldest first.
  final subscriptions = <FakeChannel>[];

  /// The last pane set that a subscribe asked for.
  List<String> watched = const [];

  /// While set, snapshot replies wait for it.
  Completer<void>? holdSnapshots;

  /// While set, subscribe replies wait for it.
  Completer<void>? holdSubscribes;

  /// Error codes to answer the next requests of a method with.
  final errors = <String, List<String>>{};

  /// Methods whose reply stops in the middle of a line, as when the
  /// connection drops.
  final torn = <String>{};

  /// Methods whose channel fails with an error of the SSH library.
  final broken = <String>{};

  /// What `pane.read` answers, by source; [paneText] for the others.
  final paneTexts = <String, String>{};
  var paneText = 'hello';

  /// While set, `pane.read` replies wait for it.
  Completer<void>? holdReads;

  /// While set, replies to input wait for it.
  Completer<void>? holdInput;

  /// Parameters of each `pane.read`, and of each input request as
  /// `(method, params)`.
  final reads = <Map<String, Object?>>[];
  final inputs = <(String, Map<String, Object?>)>[];

  int count(String method) => methods.where((m) => m == method).length;

  /// Pushes one event on the newest subscription.
  void push([String kind = 'pane_created']) => subscriptions.last.reply({
    'event': kind,
    'data': {'type': kind},
  });

  Future<void> _serve(FakeChannel c) async {
    final request = await c.request;
    final id = request['id'];
    final method = request['method']! as String;
    final params = request['params']! as Map<String, Object?>;
    methods.add(method);
    if (torn.contains(method)) {
      c.replyRaw(utf8.encode('{"id":"cut off by a dro'));
      c.end();
      return;
    }

    if (broken.contains(method)) {
      c.fail(SSHStateError('channel failed'));
      c.end();
      return;
    }

    final queued = errors[method];
    if (queued != null && queued.isNotEmpty) {
      c.reply({
        'id': id,
        'error': {'code': queued.removeAt(0), 'message': 'fake'},
      });
      c.end();
      return;
    }
    switch (method) {
      case 'session.snapshot':
        final panesNow = [...panes];
        final n = count('session.snapshot');
        await holdSnapshots?.future;
        c.reply({
          'id': id,
          'result': {
            'type': 'session_snapshot',
            'snapshot': snapshotJson ?? _snapshot(n, panesNow),
          },
        });
        c.end();
      case 'pane.read':
        reads.add(params);
        final source = params['source']! as String;
        final text = paneTexts[source] ?? paneText;
        await holdReads?.future;
        c.reply({
          'id': id,
          'result': {
            'type': 'pane_read',
            'read': {
              'pane_id': params['pane_id'],
              'workspace_id': 'w1',
              'tab_id': 'w1:t1',
              'source': source,
              'format': params['format'],
              'text': text,
              'revision': 0,
              'truncated': false,
            },
          },
        });
        c.end();
      case 'pane.send_keys' || 'pane.send_input' || 'agent.prompt':
        inputs.add((method, params));
        await holdInput?.future;
        c.reply({
          'id': id,
          'result': {
            'type': method == 'agent.prompt' ? 'agent_prompted' : 'ok',
          },
        });
        c.end();
      case 'events.subscribe':
        subscriptions.add(c);
        await holdSubscribes?.future;
        watched = [
          for (final s in params['subscriptions']! as List<Object?>)
            if ((s! as Map)['pane_id'] case final String pane) pane,
        ];
        c.reply({
          'id': id,
          'result': {'type': 'subscription_started'},
        });
    }
  }

  static const ping = HerdrPing(
    version: '0.9.5',
    protocol: 22,
    capabilities: {},
  );

  /// [HerdrSnapshot.workspaces] holds one workspace whose number tells which
  /// snapshot this was.
  static Map<String, Object?> _snapshot(int n, List<String> panes) => {
    'version': '0.9.5',
    'protocol': 22,
    'workspaces': [
      {
        'workspace_id': 'w1',
        'number': n,
        'label': 'ws',
        'focused': true,
        'pane_count': panes.length,
        'tab_count': 1,
        'active_tab_id': 'w1:t1',
        'agent_status': 'idle',
      },
    ],
    'tabs': const <Object?>[],
    'panes': [
      for (final id in panes)
        {
          'pane_id': id,
          'workspace_id': 'w1',
          'tab_id': 'w1:t1',
          'focused': false,
          'agent_status': 'idle',
          'revision': 0,
        },
    ],
    'agents': const <Object?>[],
  };
}

/// One open link to a [FakeHerdr].
class FakeLink {
  FakeLink([Map<String, Object?>? snapshot, this.screens]) {
    herdr.snapshotJson = snapshot;
  }

  final herdr = FakeHerdr();

  /// The screen streams of the link; null for a server without them.
  final ScreenOpener? screens;
  final done = Completer<void>();
  var closed = false;

  late final OpenLink open = OpenLink.herdr(
    herdr.client,
    server: FakeHerdr.ping,
    screens: screens,
    done: done.future,
    close: () {
      closed = true;
      if (!done.isCompleted) done.complete();
    },
  );
}
