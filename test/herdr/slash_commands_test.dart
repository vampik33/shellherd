import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/herdr/transcript/chat_items.dart';
import 'package:shellherd/herdr/transcript/slash_commands.dart';

/// A record of the command's output.
String _rec(String kind, String path, [String content = '']) => [
  '$slashMarker$kind $path',
  if (content.isNotEmpty)
    for (final l in content.split('\n')) '| $l',
].join('\n');

String _json(Object? value) => switch (value) {
  final String s => '"$s"',
  final Map<String, Object?> m =>
    '{${m.entries.map((e) => '"${e.key}": ${_json(e.value)}').join(', ')}}',
  final List<Object?> l => '[${l.map(_json).join(', ')}]',
  _ => '$value',
};

String _plugins(Map<String, List<Map<String, Object?>>> plugins) => _rec(
  'plugins',
  '/c/plugins/installed_plugins.json',
  _json({'version': 2, 'plugins': plugins}),
);

String _settings(String kind, Map<String, bool> enabled) =>
    _rec(kind, '/x/$kind.json', _json({'enabledPlugins': enabled}));

List<String> _names(List<SlashCommand> commands) => [
  for (final c in commands) c.name,
];

void main() {
  group('parseFrontmatter', () {
    test('plain, quoted and folded values', () {
      expect(
        parseFrontmatter(
          'description: Write it\n'
          'argument-hint: "[what] (default: all)"\n'
          'name: x',
        ),
        {
          'description': 'Write it',
          'argument-hint': '[what] (default: all)',
          'name': 'x',
        },
      );
      expect(parseFrontmatter('description: >\n  two\n  lines\nother: 1'), {
        'description': 'two lines\n',
      });
    });

    test('a YAML list is its items in brackets', () {
      expect(parseFrontmatter('argument-hint: [file]'), {
        'argument-hint': '[file]',
      });
      expect(parseFrontmatter('argument-hint: [a, b]'), {
        'argument-hint': '[a] [b]',
      });
    });

    test('YAML that does not parse is read line by line', () {
      expect(
        parseFrontmatter(
          "argument-hint: [pr] [priority]\ndescription: 'Fix it'",
        ),
        {'argument-hint': '[pr] [priority]', 'description': 'Fix it'},
      );
    });

    test('no mapping, no keys', () {
      expect(parseFrontmatter(''), isEmpty);
      expect(parseFrontmatter('- a\n- b'), isEmpty);
    });

    test('a nested list or a map gives no value', () {
      expect(parseFrontmatter('argument-hint: [[a, b], c]'), isEmpty);
      expect(parseFrontmatter('description: {a: b}'), isEmpty);
    });

    test('aliases make no long value, and take no time', () {
      // Each level is a list of ten aliases of the one before: 10^9 items.
      final yaml = StringBuffer(
        'a: &a [${List.filled(10, 'xxxxxxxxxx').join(', ')}]\n',
      );
      for (var i = 1; i <= 8; i++) {
        final before = i == 1 ? 'a' : 'b${i - 1}';
        yaml.writeln('b$i: &b$i [${List.filled(10, '*$before').join(', ')}]');
      }
      yaml
        ..writeln('s: &s ${'y' * 100}')
        ..writeln('flat: &flat [${List.filled(500, '*s').join(', ')}]')
        ..writeln('unused: *b8')
        ..writeln('description: *b8')
        ..writeln('argument-hint: *flat');
      final watch = Stopwatch()..start();
      final front = parseFrontmatter('$yaml');
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(front.keys, ['argument-hint']);
      expect(front['argument-hint']!.length, lessThanOrEqualTo(1000));
      expect(front['argument-hint'], startsWith('[${'y' * 100}] [y'));
    });
  });

  group('parseSlashCommands', () {
    test('skills, the user\'s before the project\'s, then commands, then '
        'plugins; each by name; one per name', () {
      final out = [
        'banner from .bashrc',
        _rec('user-command', '/c/commands/zeta.md', 'description: user zeta'),
        _rec('user-command', '/c/commands/dup.md', 'description: user dup'),
        _rec('user-skill', '/c/skills/alpha/SKILL.md', 'description: skill'),
        _rec(
          'project-command',
          '/p/.claude/commands/dup.md',
          'description: project dup',
        ),
        _rec('project-skill', '/p/.claude/skills/b/SKILL.md'),
        _settings('user-settings', {'tool@market': true}),
        _plugins({
          'tool@market': [
            {'scope': 'user', 'installPath': '/c/plugins/cache/m/tool/1'},
          ],
        }),
        _rec(
          'plugin',
          '/c/plugins/cache/m/tool/1/commands/run.md',
          'argument-hint: [x]',
        ),
      ].join('\n');
      final commands = parseSlashCommands(out, cwd: '/p');
      expect(_names(commands), ['alpha', 'b', 'dup', 'zeta', 'tool:run']);
      expect(commands[2].description, 'user dup');
      expect(commands.last.argumentHint, '[x]');
    });

    test('of the same name, the user\'s skill wins over the project\'s, and '
        'a skill over a command', () {
      final out = [
        _rec('project-command', '/p/.claude/commands/a.md', 'description: pc'),
        _rec('user-command', '/c/commands/a.md', 'description: uc'),
        _rec(
          'project-skill',
          '/p/.claude/skills/a/SKILL.md',
          'description: ps',
        ),
        _rec('user-skill', '/c/skills/a/SKILL.md', 'description: us'),
        _rec('project-command', '/p/.claude/commands/b.md', 'description: pc'),
        _rec('user-command', '/c/commands/b.md', 'description: uc'),
        _rec(
          'project-skill',
          '/p/.claude/skills/b/SKILL.md',
          'description: ps',
        ),
        _rec('project-command', '/p/.claude/commands/c.md', 'description: pc'),
        _rec('user-command', '/c/commands/c.md', 'description: uc'),
      ].join('\n');
      expect(parseSlashCommands(out, cwd: '/p'), const [
        SlashCommand('a', description: 'us'),
        SlashCommand('b', description: 'ps'),
        SlashCommand('c', description: 'uc'),
      ]);
    });

    test('a skill is named by its frontmatter, else its directory; one the '
        'user cannot invoke is left out', () {
      final out = [
        _rec('user-skill', '/c/skills/dir/SKILL.md', 'name: named'),
        _rec('user-skill', '/c/skills/other/SKILL.md', 'name: has space'),
        _rec(
          'user-skill',
          '/c/skills/hidden/SKILL.md',
          'user-invocable: false',
        ),
        _rec('user-skill', '/c/skills/x/README.md'),
      ].join('\n');
      expect(_names(parseSlashCommands(out)), ['named', 'other']);
    });

    test('names Claude Code does not take are dropped', () {
      final out = [
        _rec('user-command', '/c/commands/ok.md'),
        _rec('user-command', '/c/commands/has space.md'),
        _rec('user-command', '/c/commands/-dash.md'),
        _rec('user-command', '/c/commands/notes.txt'),
        _rec('user-command', 'nopath'),
        '${slashMarker}nospace',
        _rec('unknown-kind', '/c/commands/what.md'),
      ].join('\n');
      expect(_names(parseSlashCommands(out)), ['ok']);
    });

    test('a command is named from the "/./" that starts its path under '
        'commands/', () {
      final out = [
        _rec('user-command', '/c/commands/./sub/deep.md'),
        // A "/./" in the config directory comes before the one that counts.
        _rec('user-command', '/h/./c/commands/./top.md'),
        _rec('project-command', '/p/.claude/commands/./a/b/c.md'),
        _rec('user-command', '/c/commands/./sub/notes.txt'),
        // Claude Code names one at the top by the directory.
        _rec('user-command', '/c/commands/./SKILL.md'),
      ].join('\n');
      expect(_names(parseSlashCommands(out)), [
        'commands',
        'sub:deep',
        'top',
        'a:b:c',
      ]);
    });

    test('a long or multi-line description becomes one short line', () {
      final long = 'word ' * 100;
      final out = _rec(
        'user-command',
        '/c/commands/a.md',
        'description: |\n  line one\n  line two\nargument-hint: $long',
      );
      final c = parseSlashCommands(out).single;
      expect(c.description, 'line one line two');
      expect(c.argumentHint.length, 100);
      expect(c.argumentHint, endsWith('…'));
    });

    group('plugins', () {
      final files = [
        _rec('plugin', '/i/a/commands/go.md'),
        _rec('plugin', '/i/a/skills/s/SKILL.md', 'description: d'),
        _rec('plugin', '/i/a/agents/no.md'),
        _rec('plugin', '/i/b/commands/go.md'),
        _rec('plugin', '/i/old/commands/stale.md'),
      ];
      final installed = _plugins({
        'a@m': [
          {'scope': 'user', 'installPath': '/i/a/'},
        ],
        'b@m': [
          {'scope': 'project', 'projectPath': '/work/p', 'installPath': '/i/b'},
        ],
      });

      final bothOn = _settings('user-settings', {'a@m': true, 'b@m': true});

      List<String> names(List<String> settings, {String? cwd}) => _names(
        parseSlashCommands(
          [...settings, installed, ...files].join('\n'),
          cwd: cwd,
        ),
      );

      test('commands and skills under an install path, named after the '
          'plugin; other files and old versions are not', () {
        expect(names([bothOn]), ['a:go', 'a:s']);
      });

      test('a SKILL.md at the top of its commands/ is all that counts there '
          'and below; another plugin goes on', () {
        final out = [
          bothOn,
          installed,
          _rec('plugin', '/i/a/commands/./SKILL.md'),
          _rec('plugin', '/i/a/commands/./go.md'),
          _rec('plugin', '/i/a/commands/./sub/deep.md'),
          _rec('plugin', '/i/a/commands/./sub/SKILL.md'),
          _rec('plugin', '/i/b/commands/./sub/deep.md'),
        ].join('\n');
        expect(_names(parseSlashCommands(out, cwd: '/work/p')), [
          'a:commands',
          'b:sub:deep',
        ]);
      });

      test('a plugin no settings file enables does not count', () {
        expect(names(const []), isEmpty);
        expect(
          names([
            _settings('user-settings', {'b@m': true}),
          ]),
          isEmpty,
        );
      });

      test('a project plugin counts in its project and below it', () {
        expect(names([bothOn], cwd: '/work/p'), ['a:go', 'a:s', 'b:go']);
        expect(names([bothOn], cwd: '/work/p/sub'), ['a:go', 'a:s', 'b:go']);
        expect(names([bothOn], cwd: '/work/px'), ['a:go', 'a:s']);
      });

      test('local settings over project settings over the user\'s', () {
        expect(
          names([
            _settings('user-settings', {'a@m': false}),
          ]),
          isEmpty,
        );
        expect(
          names([
            _settings('user-settings', {'a@m': false}),
            _settings('project-settings', {'a@m': true}),
          ]),
          ['a:go', 'a:s'],
        );
        expect(
          names([
            _settings('user-settings', {'a@m': true}),
            _settings('project-settings', {'a@m': true}),
            _settings('local-settings', {'a@m': false}),
          ]),
          isEmpty,
        );
      });

      test('broken JSON enables nothing and lists no plugins', () {
        expect(
          _names(
            parseSlashCommands(
              [
                _rec(
                  'user-settings',
                  '/c/settings.json',
                  '{"enabledPlugins": ',
                ),
                installed,
                ...files,
              ].join('\n'),
            ),
          ),
          isEmpty,
        );
        expect(
          _names(
            parseSlashCommands(
              [
                bothOn,
                _rec('plugins', '/c/plugins/installed_plugins.json', '[1, 2'),
                ...files,
              ].join('\n'),
            ),
          ),
          isEmpty,
        );
      });
    });

    test('random output never throws, and gives only names Claude Code '
        'takes, once each', () {
      final random = Random(11);
      const pieces = [
        slashMarker,
        'user-command ',
        'user-skill ',
        'plugin ',
        'plugins ',
        '/c/commands/',
        '/i/a/skills/x/SKILL.md',
        '/i/a/commands/y.md',
        'SKILL.md',
        '.md',
        '| ',
        '| name: ',
        '| description: "',
        '| argument-hint: [',
        '| {"plugins": {"a@m": [{"installPath": "/i/a"}]}}',
        '\n',
        ' ',
        ':',
        '---',
        'é',
        '\u0000',
      ];
      for (var round = 0; round < 2000; round++) {
        final out = StringBuffer();
        for (var i = random.nextInt(40); i > 0; i--) {
          out.write(pieces[random.nextInt(pieces.length)]);
        }
        final commands = parseSlashCommands('$out', cwd: '/p');
        for (final c in commands) {
          expect(slashCommandName.hasMatch(c.name), isTrue, reason: '$out');
          expect(c.description, isNot(contains('\n')));
          expect(c.argumentHint, isNot(contains('\n')));
        }
        expect(_names(commands).toSet().length, commands.length);
      }
    });

    test('round trip: random commands, written as the command prints them, '
        'parse back', () {
      final random = Random(5);
      const letters = 'abcdefghijklmnopqrstuvwxyz0123456789-_';
      String word([int max = 8]) => [
        for (var i = 0; i < 1 + random.nextInt(max); i++)
          letters[random.nextInt(letters.length)],
      ].join();
      String text() =>
          [for (var i = 0; i < random.nextInt(4); i++) 'w${word()}'].join(' ');
      for (var round = 0; round < 300; round++) {
        // A skill wins over a command of the same name, the first of each
        // kind over the next.
        final commands = <String, SlashCommand>{};
        final skills = <String, SlashCommand>{};
        final out = <String>[];
        for (var i = random.nextInt(10); i > 0; i--) {
          final name = 'c${word()}';
          final skill = random.nextBool();
          final description = text();
          final hint = random.nextBool() ? '[${word()}]' : '';
          final front = [
            if (description.isNotEmpty)
              random.nextBool()
                  ? 'description: $description'
                  : 'description: "$description"',
            if (hint.isNotEmpty) 'argument-hint: "$hint"',
          ].join('\n');
          out.add(
            skill
                ? _rec('user-skill', '/c/skills/$name/SKILL.md', front)
                : _rec('user-command', '/c/commands/$name.md', front),
          );
          (skill ? skills : commands).putIfAbsent(
            name,
            () => SlashCommand(
              name,
              description: description,
              argumentHint: hint,
            ),
          );
        }
        final expected = {...commands, ...skills};
        final parsed = parseSlashCommands(out.join('\n'));
        expect(
          {for (final c in parsed) c.name: c},
          expected,
          reason: out.join('\n'),
        );
      }
    });
  });

  group('slashCommandsCommand', () {
    test('passes an absolute cwd as one argument, and no other', () {
      expect(
        slashCommandsCommand("/w/it's here"),
        endsWith(r" sh '/w/it'\''s here'"),
      );
      for (final cwd in [null, 'rel/dir', r'/w/back\slash', '/w/new\nline']) {
        expect(slashCommandsCommand(cwd), endsWith("' sh"), reason: '$cwd');
      }
    });

    test('the script has no backslash inside quotes, where fish reads it', () {
      // shQuote's own '\'' puts one outside quotes.
      expect(
        slashCommandsCommand(null).replaceAll(r"'\''", ''),
        isNot(contains(r'\')),
      );
    });

    group('run by sh', () {
      late Directory root;
      late Directory config;
      late Directory home;

      void put(String path, String content) => File(path)
        ..createSync(recursive: true)
        ..writeAsStringSync(content);

      setUp(() async {
        root = await Directory.systemTemp.createTemp('shellherd-slash-');
        config = Directory('${root.path}/config')..createSync();
        home = Directory('${root.path}/home')..createSync();
      });
      tearDown(() => root.delete(recursive: true));

      Future<List<SlashCommand>> run(String? cwd) async {
        final r = await Process.run(
          'sh',
          ['-c', slashCommandsCommand(cwd)],
          environment: {'CLAUDE_CONFIG_DIR': config.path, 'HOME': home.path},
        );
        expect(r.exitCode, 0, reason: '${r.stderr}');
        return parseSlashCommands(r.stdout as String, cwd: usableSlashCwd(cwd));
      }

      test('finds commands, skills and enabled plugins, and project ones up '
          'to the home directory', () async {
        final c = config.path;
        put(
          '$c/commands/mine.md',
          '---\ndescription: Mine\nargument-hint: [x]\n---\nbody\n',
        );
        put('$c/commands/sub/deep.md', '---\ndescription: deep\n---\n');
        put('$c/commands/nofront.md', 'just a body\n');
        put('$c/skills/sk/SKILL.md', '---\nname: skill\n---\n');
        final plugin = '${root.path}/plugins/tool';
        put('$plugin/commands/go.md', '---\ndescription: go\n---\n');
        put('$plugin/skills/learn/SKILL.md', '---\n---\n');
        final off = '${root.path}/plugins/off';
        put('$off/commands/no.md', '');
        put(
          '$c/plugins/installed_plugins.json',
          _json({
            'version': 2,
            'plugins': {
              'tool@m': [
                {'scope': 'user', 'installPath': plugin},
              ],
              'off@m': [
                {'scope': 'user', 'installPath': off},
              ],
            },
          }),
        );
        put(
          '$c/settings.json',
          '{"enabledPlugins": {"tool@m": true, "off@m": false}}',
        );
        // Above the home directory: not read.
        put('${root.path}/.claude/commands/above.md', '');
        put('${home.path}/.claude/commands/homedir.md', '');
        final project = "${home.path}/my project/it's/sub";
        put(
          '${home.path}/my project/.claude/commands/proj.md',
          '---\ndescription: "Proj"\n---\n',
        );
        put(
          '$project/.claude/skills/here/SKILL.md',
          '---\ndescription: here\n---\n',
        );

        final commands = await run(project);
        expect(_names(commands), [
          'skill',
          'here',
          'mine',
          'nofront',
          'sub:deep',
          'proj',
          'tool:go',
          'tool:learn',
        ]);
        expect(
          commands[2],
          const SlashCommand('mine', description: 'Mine', argumentHint: '[x]'),
        );
        // Without a cwd, nothing of the project.
        expect(_names(await run(null)), [
          'skill',
          'mine',
          'nofront',
          'sub:deep',
          'tool:go',
          'tool:learn',
        ]);
      });

      test('a command in a subdirectory is named by its path, as Claude '
          'Code does', () async {
        final c = config.path;
        put('$c/commands/a/test.md', '---\ndescription: a\n---\n');
        put('$c/commands/b/test.md', '---\ndescription: b\n---\n');
        put('$c/commands/a/b/c.md', '');
        // Deeper than the read looks.
        put('$c/commands/a/b/c/d.md', '');
        // A name Claude Code does not take.
        put('$c/commands/with space/x.md', '');
        // A directory with a SKILL.md gives only that, named by the
        // directory.
        put('$c/commands/ops/deploy/SKILL.md', '---\ndescription: d\n---\n');
        put('$c/commands/ops/deploy/notes.md', '');
        // Only a plugin's SKILL.md counts in any case.
        put('$c/commands/loud/SKILL.MD', '');
        // Below a SKILL.md, the user's commands go on.
        put('$c/commands/kit/SKILL.md', '');
        put('$c/commands/kit/more/x.md', '');
        // Hidden, a skill or not.
        put('$c/commands/hid/SKILL.md', '---\nuser-invocable: false\n---\n');
        put('$c/commands/quiet.md', '---\nuser-invocable: False\n---\n');
        final plugin = '${root.path}/plugins/tool';
        put('$plugin/commands/db/migrate.md', '');
        put('$plugin/commands/up/Skill.md', '');
        put('$plugin/commands/up/notes.md', '');
        // Below a plugin's SKILL.md, nothing more counts.
        put('$plugin/commands/up/deeper/no.md', '');
        put('$plugin/commands/big/SKILL.MD', '');
        put('$plugin/commands/big/notes.md', '');
        put(
          '$c/plugins/installed_plugins.json',
          _json({
            'version': 2,
            'plugins': {
              'tool@m': [
                {'scope': 'user', 'installPath': plugin},
              ],
            },
          }),
        );
        put('$c/settings.json', '{"enabledPlugins": {"tool@m": true}}');
        final project = '${home.path}/work';
        put('$project/.claude/commands/front/component.md', '');

        final commands = await run(project);
        expect(_names(commands), [
          'a:b:c',
          'a:test',
          'b:test',
          'kit',
          'kit:more:x',
          'ops:deploy',
          'front:component',
          'tool:big',
          'tool:db:migrate',
          'tool:up',
        ]);
        expect(commands[5].description, 'd');
        expect(commands[1].description, 'a');
        expect(commands[2].description, 'b');
      });

      test("what is below a plugin's SKILL.md does not count against the "
          'cap of what is read', () async {
        final c = config.path;
        final plugin = '${root.path}/plugins/tool';
        put('$plugin/commands/big/SKILL.md', '');
        for (var i = 0; i < 250; i++) {
          put('$plugin/commands/big/ref/r$i.md', '');
        }
        // Below the depth the read looks at: not a skill of the plugin.
        put('$plugin/commands/a/b/c/SKILL.md', '');
        // Beside it, some found after it whatever order find takes.
        final siblings = [for (var i = 10; i < 40; i++) 'go$i'];
        for (final name in siblings) {
          put('$plugin/commands/$name.md', '');
        }
        put(
          '$c/plugins/installed_plugins.json',
          _json({
            'version': 2,
            'plugins': {
              'tool@m': [
                {'scope': 'user', 'installPath': plugin},
              ],
            },
          }),
        );
        put('$c/settings.json', '{"enabledPlugins": {"tool@m": true}}');
        expect(_names(await run(null)), [
          'tool:big',
          for (final name in siblings) 'tool:$name',
        ]);
      });

      test('an empty config directory has no commands', () async {
        expect(await run('/'), isEmpty);
        expect(await run('${root.path}/missing'), isEmpty);
      });
    });
  });

  group('slashQuery', () {
    test('a slash and a name being typed', () {
      expect(slashQuery('/'), '');
      expect(slashQuery('/comp'), 'comp');
      expect(slashQuery('/codex:re'), 'codex:re');
    });
    test('anything else', () {
      for (final text in [
        '',
        'hi',
        ' /x',
        '/x ',
        '/x y',
        '/x\n',
        '/etc/hosts',
      ]) {
        expect(slashQuery(text), isNull, reason: text);
      }
    });
  });

  test('recentSlashCommands: the latest first, once each, only prompts', () {
    final items = <ChatItem>[
      const ChatPrompt('/compact keep the tests'),
      const ChatPrompt('/etc/hosts is broken'),
      const ChatReply('/clear'),
      const ChatPrompt('/review 12'),
      const ChatPrompt('plain'),
      const ChatPrompt('/compact'),
    ];
    expect(recentSlashCommands(items), ['compact', 'review']);
    expect(recentSlashCommands(items, max: 1), ['compact']);
    expect(recentSlashCommands(const []), isEmpty);
  });

  group('slashMatches', () {
    const found = [
      SlashCommand('mine'),
      SlashCommand('codex:review'),
      SlashCommand('compare'),
      SlashCommand('clear', description: 'custom'),
    ];

    test('all: found first, then the built-ins; one per name', () {
      final all = slashMatches('', found);
      expect(_names(all), [
        'mine',
        'codex:review',
        'compare',
        'clear',
        'compact',
        'context',
        'init',
        'review',
        'security-review',
      ]);
      expect(all[3].description, 'custom');
    });

    test('starts with, then a part after a colon, then contains; any '
        'case', () {
      expect(_names(slashMatches('REV', found)), [
        'review',
        'codex:review',
        'security-review',
      ]);
      expect(_names(slashMatches('re', found)), [
        'review',
        'codex:review',
        'compare',
        'security-review',
      ]);
      expect(slashMatches('zzz', found), isEmpty);
    });

    test('recent ones first in each group; unknown recent ones do not '
        'show', () {
      expect(
        _names(slashMatches('c', found, recent: ['model', 'compact', 'clear'])),
        [
          'compact',
          'clear',
          'codex:review',
          'compare',
          'context',
          'security-review',
        ],
      );
    });
  });

  group('SlashCommands', () {
    late DateTime now;
    late List<String?> asked;
    late Completer<List<SlashCommand>> answer;
    late SlashCommands commands;

    Future<List<SlashCommand>> lookup(String? cwd) {
      asked.add(cwd);
      return answer.future;
    }

    setUp(() {
      now = DateTime(2026);
      asked = [];
      answer = Completer();
      commands = SlashCommands(now: () => now);
    });
    tearDown(() => commands.dispose());

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('reads once while current, again when old or for another '
        'directory', () async {
      var notified = 0;
      commands.addListener(() => notified++);
      commands.want(null, '/p');
      expect(asked, isEmpty);
      commands.want(lookup, '/p');
      commands.want(lookup, '/p');
      expect(asked, ['/p']);
      expect(commands.loading, isTrue);
      answer.complete(const [SlashCommand('a')]);
      await settle();
      expect(commands.loading, isFalse);
      expect(commands.found, const [SlashCommand('a')]);
      expect(notified, 2);

      commands.want(lookup, '/p');
      now = now.add(const Duration(seconds: 59));
      commands.want(lookup, '/p');
      expect(asked, ['/p']);
      now = now.add(const Duration(seconds: 1));
      answer = Completer();
      commands.want(lookup, '/p');
      expect(asked, ['/p', '/p']);
      answer.complete(const []);
      await settle();
      answer = Completer();
      commands.want(lookup, '/q');
      expect(asked, ['/p', '/p', '/q']);
      answer.complete(const []);
      await settle();
    });

    test('a failed read keeps what was found for the same directory, not '
        'for another, and is tried again when old', () async {
      commands.want(lookup, '/p');
      answer.complete(const [SlashCommand('a')]);
      await settle();
      now = now.add(const Duration(minutes: 1));
      answer = Completer()..completeError(StateError('down'));
      commands.want(lookup, '/p');
      await settle();
      expect(commands.failed, isTrue);
      expect(commands.found, const [SlashCommand('a')]);
      commands.want(lookup, '/p');
      expect(asked.length, 2);

      answer = Completer();
      commands.want(lookup, '/q');
      expect(commands.found, isEmpty, reason: 'not the commands of /p');
      answer.completeError(StateError('down'));
      await settle();
      expect(commands.found, isEmpty);
      expect(commands.failed, isTrue);

      now = now.add(const Duration(minutes: 1));
      answer = Completer()..complete(const [SlashCommand('b')]);
      commands.want(lookup, '/q');
      await settle();
      expect(commands.failed, isFalse);
      expect(commands.found, const [SlashCommand('b')]);
    });

    test('a read that ends after dispose changes nothing', () async {
      final other = SlashCommands();
      other.want(lookup, '/p');
      other.dispose();
      answer.complete(const [SlashCommand('a')]);
      await settle();
      expect(other.found, isEmpty);
    });
  });
}
