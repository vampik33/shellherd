import 'dart:async';

import 'package:shellherd/herdr/api/hc_client.dart';

import 'fake_channel.dart';

/// A terminal as herdr-core lists it.
Map<String, Object?> hcTerminal(
  String address, {
  String state = 'live',
  Map<String, String> labels = const {},
  Map<String, Object?>? status,
  int turn = 0,
  String? name,
  String? parent,
  String title = '',
  String cwd = '/home/u/work',
}) => {
  'address': address,
  'argv': ['/bin/sh'],
  'cols': 80,
  'rows': 24,
  'created_ms': 1,
  'cwd': cwd,
  'labels': labels,
  'state': state,
  'screen': 'exact',
  'title': title,
  'turn': turn,
  'name': ?name,
  'parent': ?parent,
  'status': ?status,
  'foreground': {
    'pid': 1,
    'name': 'sh',
    'argv': ['sh'],
    'cwd': cwd,
  },
};

/// One tab of the app's layout: a row of terminal panes.
Map<String, Object?> hcTab(
  String id,
  List<String> terminals, {
  String name = '',
}) => {
  'id': id,
  'name': name,
  'root': {
    'id': id,
    'type': 'row',
    'children': [
      for (final (i, t) in terminals.indexed)
        {
          'id': 'p$id$i',
          'type': 'block',
          'content': {'terminal': t},
        },
    ],
  },
};

Map<String, Object?> hcSpace(
  String id,
  List<Map<String, Object?>> tabs, {
  String name = '',
  String folder = '/home/u/work',
}) => {'id': id, 'name': name, 'folder': folder, 'tabs': tabs};

/// A herdr-core in memory. It answers every request on a channel by its
/// method, as the real one answers many requests per connection: one at a
/// time, so a request it holds back holds up the ones behind it.
class FakeHc {
  FakeHc() {
    dialer.dialed.listen(_serve);
  }

  final dialer = FakeDialer();

  var terminals = [
    hcTerminal('t1', labels: {'herdr.space': 's1', 'herdr.tab': 'b1'}),
  ];

  /// The value of the `herdr-app` document; null when never written.
  Object? layout = {
    'spaces': [
      hcSpace('s1', [
        hcTab('b1', ['t1']),
      ]),
    ],
  };

  var text = 'hello';
  var generation = 1;

  /// Methods in the order they arrived.
  final methods = <String>[];

  /// Params of each request, in order.
  final requests = <(String, Map<String, Object?>)>[];

  /// Subscription channels, oldest first.
  final subscriptions = <FakeChannel>[];

  /// Error kinds to answer the next requests of a method with.
  final errors = <String, List<String>>{};

  /// While set, `terminal.list` replies wait for it.
  Completer<void>? holdLists;

  /// While set, `terminal.send` replies wait for it, as for a person's
  /// draft on the PC.
  Completer<void>? holdSends;

  /// Methods that get no reply at all.
  final silent = <String>{};

  int count(String method) => methods.where((m) => m == method).length;

  Future<HcClient> connect({Duration timeout = const Duration(seconds: 2)}) =>
      HcClient.connect(dialer.call, timeout: timeout);

  /// Sends a notification on the newest subscription.
  void note(String method) => subscriptions.last.reply({
    'jsonrpc': '2.0',
    'method': method,
    'params': {'seq': 1},
  });

  void _serve(FakeChannel c) {
    var turn = Future<void>.value();
    c.writes.listen((request) {
      turn = turn.then((_) => _answer(c, request));
    });
  }

  Future<void> _answer(FakeChannel c, Map<String, Object?> request) async {
    final id = request['id'];
    final method = request['method']! as String;
    final params = request['params']! as Map<String, Object?>;
    methods.add(method);
    requests.add((method, params));
    if (silent.contains(method)) return;
    final queued = errors[method];
    if (queued != null && queued.isNotEmpty) {
      c.reply({
        'jsonrpc': '2.0',
        'id': id,
        'error': {
          'code': -32000,
          'message': 'fake',
          'data': {'kind': queued.removeAt(0)},
        },
      });
      return;
    }
    final Map<String, Object?> result;
    switch (method) {
      case 'hello':
        result = {
          'generation': generation,
          'version': '0.1.20',
          'core': {'id': 'c', 'name': 'box'},
          'framed': false,
          'methods': const <String>[],
          'features': const <String>[],
        };
      case 'terminal.list':
        final now = [...terminals];
        await holdLists?.future;
        result = {'terminals': now, 'hidden_finished': 0};
      case 'terminal.get':
        result = terminals.singleWhere(
          (t) => t['address'] == params['terminal'],
        );
      case 'doc.get':
        result = {'value': layout, 'version': layout == null ? 0 : 1};
      case 'terminal.read':
        result = {'text': text, 'complete': true, 'how': 'screen'};
      case 'terminal.keys':
        result = {'turn': 0};
      case 'terminal.send':
        await holdSends?.future;
        result = {'turn': 0};
      case 'events.subscribe':
        subscriptions.add(c);
        result = {'seq': 0, 'terminals': terminals};
      default:
        result = {};
    }
    c.reply({'jsonrpc': '2.0', 'id': id, 'result': result});
  }
}
