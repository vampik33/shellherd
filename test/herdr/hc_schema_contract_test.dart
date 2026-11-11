/// Checks every request HcClient sends against the OpenRPC document that
/// the installed herdr-core prints with `hc schema`. An update that renames
/// a method or a param fails here before it fails on a phone.
@Tags(['hc'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:json_schema/json_schema.dart';
import 'package:shellherd/herdr/api/hc_client.dart';

import '../support/fake_hc.dart';

Future<void> main() async {
  Map<String, Object?>? root;
  try {
    final r = await Process.run('hc', ['schema']);
    if (r.exitCode == 0) {
      root = jsonDecode(r.stdout as String) as Map<String, Object?>;
    }
  } on ProcessException {
    root = null;
  }

  group(
    'requests match hc schema',
    skip: root == null ? 'hc is not on PATH' : false,
    () {
      late Map<String, Map<String, Object?>> methods;

      setUpAll(() {
        methods = {
          for (final m
              in (root!['methods']! as List).cast<Map<String, Object?>>())
            m['name']! as String: m,
        };
      });

      /// The errors of [request] against its method: unknown method, a
      /// param it does not take, a missing required one, a wrong value.
      List<String> problems(String method, Map<String, Object?> params) {
        final spec = methods[method];
        if (spec == null) return ['no method $method'];
        final declared = {
          for (final p
              in (spec['params']! as List).cast<Map<String, Object?>>())
            p['name']! as String: p,
        };
        return [
          for (final name in params.keys)
            if (!declared.containsKey(name)) '$method takes no "$name"',
          for (final MapEntry(key: name, value: p) in declared.entries)
            if (p['required'] == true && !params.containsKey(name))
              '$method needs "$name"',
          for (final MapEntry(key: name, value: value) in params.entries)
            if (declared[name] case final p?)
              ...JsonSchema.create(
                {
                  ...(p['schema']! as Map<String, Object?>),
                  'components': root!['components'],
                },
                schemaVersion: SchemaVersion.draft2020_12,
              ).validate(value).errors.map((e) => '$method.$name: $e'),
        ];
      }

      /// The requests [call] makes on a fake core.
      Future<List<(String, Map<String, Object?>)>> sent(
        Future<void> Function(HcClient c) call,
      ) async {
        final hc = FakeHc();
        final client = await hc.connect();
        await call(client);
        await client.close();
        return hc.requests;
      }

      test('the gate rejects a request herdr-core would reject', () {
        expect(problems('terminal.read', {'lines': 3}), isNotEmpty);
        expect(
          problems('terminal.read', {'terminal': 't1', 'lines': -1}),
          isNotEmpty,
        );
        expect(
          problems('terminal.read', {'terminal': 't1', 'nope': 1}),
          isNotEmpty,
        );
        expect(problems('no.such', {}), isNotEmpty);
      });

      test('every request the app sends', () async {
        final requests = await sent((c) async {
          await c.terminals();
          await c.layout();
          await c.read('t1', lines: 0);
          await c.read('t1', lines: 400);
          await c.keys('t1', ['esc', 'shift+tab', '1']);
          await c.send('t1', 'hi');
          await (await c.subscribe()).close();
        });
        expect(requests.map((r) => r.$1).toSet(), {
          'hello',
          'terminal.list',
          'doc.get',
          'terminal.read',
          'terminal.keys',
          'terminal.send',
          'events.subscribe',
        });
        for (final (method, params) in requests) {
          expect(problems(method, params), isEmpty, reason: '$method $params');
        }
      });
    },
  );
}
