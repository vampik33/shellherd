import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/hc_link.dart';

void main() {
  group('hcSessionName', () {
    test('null, empty and blank are the default session', () {
      for (final s in [null, '', '  ']) {
        expect(hcSessionName(s), 'default', reason: '$s');
      }
    });

    test('drops spaces around the name and keeps a leading dot', () {
      expect(hcSessionName(' work '), 'work');
      expect(hcSessionName('.hidden'), '.hidden');
      expect(hcSessionName('a.b-c_d'), 'a.b-c_d');
    });

    test('rejects what cannot be a folder name, as hc does', () {
      for (final bad in [
        '.',
        '..',
        'a/b',
        r'a\b',
        'a:b',
        'a*',
        'a?',
        'a"b',
        '<a>',
        'a|b',
        'a\tb',
        'a\u{85}b',
      ]) {
        expect(() => hcSessionName(bad), throwsArgumentError, reason: bad);
      }
    });
  });

  group('hcSocketPath', () {
    test('beside the other sessions in the runtime dir', () {
      expect(
        hcSocketPath('run /run/user/1000', 'default'),
        '/run/user/1000/herdr-core/default.sock',
      );
    });

    test('in a folder of its own under the state home', () {
      expect(
        hcSocketPath('state /home/u/.local/state', 'work'),
        '/home/u/.local/state/herdr-core/work/work.sock',
      );
      expect(
        hcSocketPath('state /a b/state', 'w'),
        '/a b/state/herdr-core/w/w.sock',
      );
    });

    test('anything else is not a base', () {
      for (final bad in ['', 'run', 'run ', 'run relative', '/run/user/1', 'x /a']) {
        expect(hcSocketPath(bad, 'default'), isNull, reason: bad);
      }
    });
  });

  group('hcSocketBase in sh', () {
    Future<String> base(
      Map<String, String?> env, {
      String expression = hcSocketBase,
    }) async {
      final environment = {...Platform.environment};
      env.forEach((k, v) => v == null ? environment.remove(k) : environment[k] = v);
      final r = await Process.run(
        'sh',
        ['-c', 'printf "%s" "$expression"'],
        environment: environment,
        includeParentEnvironment: false,
      );
      expect(r.exitCode, 0, reason: '${r.stderr}');
      return r.stdout as String;
    }

    test('a set XDG_RUNTIME_DIR wins', () async {
      expect(await base({'XDG_RUNTIME_DIR': '/x/run'}), 'run /x/run');
    });

    final uid = (Process.runSync('id', ['-u']).stdout as String).trim();
    final runUser = Directory('/run/user/$uid').existsSync();

    test('unset or empty, /run/user/<uid> if it exists', () async {
      for (final run in [null, '']) {
        expect(await base({'XDG_RUNTIME_DIR': run}), 'run /run/user/$uid');
      }
    }, skip: runUser ? false : 'no /run/user/$uid here');

    test('else the state home', () async {
      // As on a host with no /run/user/<uid>.
      final noRunUser = hcSocketBase.replaceAll(
        '/run/user/',
        '/shellherd-no-such-dir/',
      );
      expect(
        await base({
          'XDG_RUNTIME_DIR': null,
          'XDG_STATE_HOME': '/x/state',
        }, expression: noRunUser),
        'state /x/state',
      );
      expect(
        await base({
          'XDG_RUNTIME_DIR': '',
          'XDG_STATE_HOME': '',
          'HOME': '/h',
        }, expression: noRunUser),
        'state /h/.local/state',
      );
    });
  });
}
