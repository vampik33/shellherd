import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:yaml/yaml.dart';

import '../../ssh/ssh_exec.dart';
import 'chat_items.dart';

/// A slash command that Claude Code takes, for the composer's menu.
@immutable
class SlashCommand {
  const SlashCommand(
    this.name, {
    this.description = '',
    this.argumentHint = '',
  });

  /// Without the slash, such as `compact` or `codex:review`.
  final String name;

  /// One line; empty where the command has none.
  final String description;

  /// What the command takes after its name, such as `[instructions]`.
  final String argumentHint;

  @override
  bool operator ==(Object other) =>
      other is SlashCommand &&
      other.name == name &&
      other.description == description &&
      other.argumentHint == argumentHint;

  @override
  int get hashCode => Object.hash(name, description, argumentHint);

  @override
  String toString() => 'SlashCommand(/$name, $argumentHint, $description)';
}

/// Claude Code's own commands that run from the chat: each sends a prompt
/// or prints text into the transcript. Commands that open a picker or a
/// panel in the terminal, such as `/model` or `/resume`, are left out:
/// the chat cannot show it.
const builtInSlashCommands = [
  SlashCommand('clear', description: 'Start a new session with empty context'),
  SlashCommand(
    'compact',
    description: 'Free up context by summarizing the conversation so far',
    argumentHint: '[instructions]',
  ),
  SlashCommand('context', description: 'Show what fills the context'),
  SlashCommand(
    'init',
    description: 'Initialize a new CLAUDE.md file with codebase documentation',
  ),
  SlashCommand('review', description: 'Review a pull request'),
  SlashCommand(
    'security-review',
    description: 'Complete a security review of the pending changes',
  ),
];

/// Finds the custom commands, skills and plugin commands that Claude Code
/// offers in the directory cwd on the remote host, in the menu's order.
typedef SlashCommandLookup = Future<List<SlashCommand>> Function(String? cwd);

/// Marks each record of [slashCommandsCommand]'s output: the kind and the
/// path follow. Lines before the first come from the shell's startup
/// files.
const slashMarker = 'shellherd-slash ';

/// Marks each line of a record's content.
const _contentMark = '| ';

/// The longest output that is read; the rest is dropped.
const maxSlashOutput = 1024 * 1024;

/// Names Claude Code takes: no space, no slash. Plugin commands have the
/// plugin's name and a colon in front.
final slashCommandName = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.:-]{0,99}$');

/// Prints, as records of [slashMarker], the kind and the path, then the
/// content with each line after `| `:
///
/// - `user-settings`, `project-settings`, `local-settings`: the
///   settings files that enable plugins, whole;
/// - `plugins`: `plugins/installed_plugins.json`, whole;
/// - `user-command`, `user-skill`, `project-command`, `project-skill`,
///   `plugin`: the frontmatter of a command (`commands/**/*.md`) or a
///   skill (`skills/*/SKILL.md`).
///
/// The config directory is CLAUDE_CONFIG_DIR or `~/.claude`. Project
/// commands and skills are in `.claude` of [cwd] and of each directory
/// above it, up to the home directory; project settings only in [cwd].
/// Plugin files are those under each `installPath` of
/// `installed_plugins.json`; which of them count is for
/// [parseSlashCommands] to decide.
///
/// [cwd] goes in only when it is absolute and has no backslash or control
/// character, which fish would read inside single quotes. Through `sh`,
/// because the login shell can be fish.
String slashCommandsCommand(String? cwd) {
  final inner = [
    'd="\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}"',
    'cwd=\$1',
    'emit_file() {',
    '  [ -f "\$2" ] && [ -r "\$2" ] || return 0',
    '  echo "$slashMarker\$1 \$2"',
    "  head -c 262144 -- \"\$2\" | sed 's/^/$_contentMark/'",
    '  echo',
    '}',
    'emit_md() {',
    '  [ -f "\$2" ] && [ -r "\$2" ] || return 0',
    '  echo "$slashMarker\$1 \$2"',
    "  head -c 16384 -- \"\$2\" | awk 'NR == 1 && !/^---[[:space:]]*\$/ { exit }",
    '    NR > 1 && /^---[[:space:]]*\$/ { exit }',
    "    NR > 1 && NR <= 80 { print \"$_contentMark\" \$0 }'",
    '}',
    'emit_commands() {',
    '  [ -d "\$2" ] || return 0',
    "  find -L \"\$2\" -maxdepth 3 -type f -name '*.md' 2>/dev/null |",
    '    head -n 200 | while IFS= read -r f; do emit_md "\$1" "\$f"; done',
    '}',
    'emit_skills() {',
    '  for f in "\$2"/*/SKILL.md; do emit_md "\$1" "\$f"; done',
    '}',
    // Settings and plugins first: a read cut at the cap loses the
    // project's commands of the farthest directories, not the plugins.
    'emit_file user-settings "\$d/settings.json"',
    'if [ -n "\$cwd" ] && [ -d "\$cwd" ]; then',
    '  emit_file project-settings "\$cwd/.claude/settings.json"',
    '  emit_file local-settings "\$cwd/.claude/settings.local.json"',
    'fi',
    'i="\$d/plugins/installed_plugins.json"',
    'if [ -r "\$i" ]; then',
    '  emit_file plugins "\$i"',
    "  head -c 262144 -- \"\$i\" | awk -F'\"' '{",
    '    for (k = 1; k < NF; k++) if (\$k == "installPath") print \$(k + 2)',
    "  }' | head -n 100 | while IFS= read -r ip; do",
    '    emit_commands plugin "\$ip/commands"',
    '    emit_skills plugin "\$ip/skills"',
    '  done',
    'fi',
    'emit_commands user-command "\$d/commands"',
    'emit_skills user-skill "\$d/skills"',
    'if [ -n "\$cwd" ] && [ -d "\$cwd" ]; then',
    '  p=\$cwd',
    '  while [ "\$p" != "\$HOME" ] && [ "\$p" != . ]; do',
    '    emit_commands project-command "\$p/.claude/commands"',
    '    emit_skills project-skill "\$p/.claude/skills"',
    '    [ "\$p" = / ] && break',
    '    p=\$(dirname -- "\$p")',
    '  done',
    'fi',
    'exit 0',
  ].join('\n');
  final dir = usableSlashCwd(cwd);
  final arg = dir == null ? '' : ' ${shQuote(dir)}';
  return 'sh -c ${shQuote(inner)} sh$arg';
}

/// [cwd] when [slashCommandsCommand] can take it, else null.
String? usableSlashCwd(String? cwd) {
  if (cwd == null || !cwd.startsWith('/')) return null;
  if (cwd.contains(r'\') || cwd.codeUnits.any((c) => c < 0x20 || c == 0x7f)) {
    return null;
  }
  return cwd;
}

/// One record of [slashCommandsCommand]'s output.
class _Record {
  _Record(this.kind, this.path);
  final String kind;
  final String path;
  final lines = <String>[];
  String get content => lines.join('\n');
}

List<_Record> _records(String output) {
  final records = <_Record>[];
  _Record? current;
  for (final line in const LineSplitter().convert(output)) {
    if (line.startsWith(slashMarker)) {
      final rest = line.substring(slashMarker.length);
      final space = rest.indexOf(' ');
      current = space <= 0
          ? null
          : _Record(rest.substring(0, space), rest.substring(space + 1));
      if (current != null) records.add(current);
    } else if (current != null && line.startsWith(_contentMark)) {
      current.lines.add(line.substring(_contentMark.length));
    }
  }
  return records;
}

/// The commands in [output] of [slashCommandsCommand] for [cwd], in the
/// menu's order: project commands and skills, the user's, then those of
/// plugins, each group by name. One per name, the first.
///
/// A plugin counts when `installed_plugins.json` lists it with an entry
/// for all projects or for the project of [cwd], and the settings enable
/// it (`enabledPlugins` true; local settings over project settings over
/// the user's), as Claude Code writes on install. Its commands are `<plugin>:<name>`. A skill whose
/// frontmatter says `user-invocable: false` is left out.
List<SlashCommand> parseSlashCommands(String output, {String? cwd}) {
  final records = _records(output);
  final enabled = <String, bool>{};
  for (final kind in const [
    'user-settings',
    'project-settings',
    'local-settings',
  ]) {
    for (final r in records.where((r) => r.kind == kind)) {
      if (_json(r.content) case {
        'enabledPlugins': final Map<String, Object?> m,
      }) {
        for (final MapEntry(:key, :value) in m.entries) {
          if (value is bool) enabled[key] = value;
        }
      }
    }
  }
  // Plugin name by install path, of the plugins that count.
  final plugins = <String, String>{};
  for (final r in records.where((r) => r.kind == 'plugins')) {
    if (_json(r.content) case {
      'plugins': final Map<String, Object?> installed,
    }) {
      for (final MapEntry(:key, :value) in installed.entries) {
        final name = key.split('@').first;
        if (enabled[key] != true || !slashCommandName.hasMatch(name)) continue;
        if (value is! List) continue;
        for (final entry in value) {
          if (entry is Map && _forProject(entry, cwd)) {
            if (entry['installPath'] case final String path) {
              plugins[_trimSlash(path)] = name;
              break;
            }
          }
        }
      }
    }
  }
  final groups = {
    for (final kind in const [
      'project-command',
      'project-skill',
      'user-command',
      'user-skill',
      'plugin',
    ])
      kind: <SlashCommand>[],
  };
  for (final r in records) {
    final group = groups[r.kind];
    if (group == null) continue;
    final command = r.kind == 'plugin'
        ? _pluginCommand(r, plugins)
        : _command(r, skill: r.kind.endsWith('-skill'));
    if (command != null) group.add(command);
  }
  // One per name: in a group the first found, then the first group.
  final seen = <String>{};
  return [
    for (final group in groups.values)
      for (final c in _byName(group))
        if (seen.add(c.name)) c,
  ];
}

/// [commands] by name, the first of each name only.
List<SlashCommand> _byName(List<SlashCommand> commands) {
  final first = <String, SlashCommand>{};
  for (final c in commands) {
    first.putIfAbsent(c.name, () => c);
  }
  return first.values.toList()..sort((a, b) => a.name.compareTo(b.name));
}

Object? _json(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}

String _trimSlash(String path) => path.length > 1 && path.endsWith('/')
    ? path.substring(0, path.length - 1)
    : path;

/// An entry of `installed_plugins.json` counts for all projects, or for
/// the project it names when [cwd] is in it.
bool _forProject(Map<Object?, Object?> entry, String? cwd) {
  final scope = entry['scope'];
  if (scope != 'project' && scope != 'local') return true;
  final project = entry['projectPath'];
  if (project is! String || cwd == null) return false;
  final root = _trimSlash(project);
  return cwd == root || cwd.startsWith(root == '/' ? '/' : '$root/');
}

SlashCommand? _pluginCommand(_Record r, Map<String, String> plugins) {
  for (final MapEntry(key: root, value: plugin) in plugins.entries) {
    if (!r.path.startsWith('$root/')) continue;
    final rel = r.path.substring(root.length + 1);
    final skill = rel.startsWith('skills/');
    if (!skill && !rel.startsWith('commands/')) continue;
    final command = _command(r, skill: skill);
    if (command == null) return null;
    final name = '$plugin:${command.name}';
    if (!slashCommandName.hasMatch(name)) return null;
    return SlashCommand(
      name,
      description: command.description,
      argumentHint: command.argumentHint,
    );
  }
  return null;
}

/// A command from its file: a skill is named by its frontmatter or its
/// directory, a command by its file.
SlashCommand? _command(_Record r, {required bool skill}) {
  final parts = r.path.split('/');
  if (parts.length < 2) return null;
  final front = parseFrontmatter(r.content);
  final String fallback;
  if (skill) {
    if (parts.last != 'SKILL.md') return null;
    fallback = parts[parts.length - 2];
  } else {
    if (!parts.last.endsWith('.md')) return null;
    fallback = parts.last.substring(0, parts.last.length - 3);
  }
  if (skill && front['user-invocable']?.toLowerCase() == 'false') return null;
  final named = skill ? front['name'] : null;
  final name = named != null && slashCommandName.hasMatch(named)
      ? named
      : fallback;
  if (!slashCommandName.hasMatch(name)) return null;
  return SlashCommand(
    name,
    description: _oneLine(front['description'] ?? '', 300),
    argumentHint: _oneLine(front['argument-hint'] ?? '', 100),
  );
}

String _oneLine(String s, int max) {
  final line = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return line.length <= max ? line : '${line.substring(0, max - 1)}…';
}

/// The scalar keys of YAML frontmatter [text], as strings. A list becomes
/// its items, each in brackets: `argument-hint: [file]` is YAML for a
/// list. Where the YAML does not parse, as for `argument-hint: [a] [b]`,
/// each `key: value` line counts, without its quotes.
Map<String, String> parseFrontmatter(String text) {
  Object? yaml;
  try {
    yaml = loadYaml(text);
  } on Exception {
    yaml = null;
  }
  if (yaml is YamlMap) {
    return {
      for (final MapEntry(:key, :value) in yaml.entries)
        if (key is String) key: ?_scalar(value),
    };
  }
  if (yaml != null) return {};
  final line = RegExp(r'^([A-Za-z][A-Za-z0-9_-]*):[ \t]*(.*)$');
  return {
    for (final l in const LineSplitter().convert(text))
      if (line.firstMatch(l) case final m?) m[1]!: _unquote(m[2]!.trim()),
  };
}

String? _scalar(Object? value) => switch (value) {
  final String s => s,
  num() || bool() => '$value',
  final YamlList l => l.map((v) => '[${_scalar(v) ?? ''}]').join(' '),
  _ => null,
};

String _unquote(String s) {
  if (s.length >= 2 &&
      ((s.startsWith('"') && s.endsWith('"')) ||
          (s.startsWith("'") && s.endsWith("'")))) {
    return s.substring(1, s.length - 1);
  }
  return s;
}

/// A [SlashCommandLookup] that runs [slashCommandsCommand] on the remote
/// host, on its own bounded exec channel. Reads at most [maxSlashOutput]
/// bytes; a file cut inside a character does not fail the read.
SlashCommandLookup sshSlashCommandLookup(
  SSHClient ssh, {
  Duration timeout = const Duration(seconds: 15),
}) => (cwd) async {
  final session = await openExec(ssh, slashCommandsCommand(cwd), timeout);
  try {
    await session.stdin.close();
    final bytes = BytesBuilder(copy: false);
    await () async {
      await for (final chunk in session.stdout) {
        bytes.add(chunk);
        if (bytes.length >= maxSlashOutput) break;
      }
    }().timeout(timeout);
    final out = utf8.decode(bytes.takeBytes(), allowMalformed: true);
    return parseSlashCommands(out, cwd: usableSlashCwd(cwd));
  } finally {
    session.channel.destroy();
  }
};

/// The query of the menu: what follows the slash of [text] while [text] is
/// a slash and a name being typed, else null.
String? slashQuery(String text) {
  if (!text.startsWith('/')) return null;
  final query = text.substring(1);
  if (query.contains(RegExp(r'[\s/]'))) return null;
  return query;
}

/// The commands run lately in [items], the latest first: the names of
/// prompts that start with a slash.
List<String> recentSlashCommands(List<ChatItem> items, {int max = 5}) {
  final recent = <String>[];
  for (final item in items.reversed) {
    if (item is! ChatPrompt || !item.text.startsWith('/')) continue;
    final name = item.text.substring(1).split(RegExp(r'\s')).first;
    if (!slashCommandName.hasMatch(name) || recent.contains(name)) continue;
    recent.add(name);
    if (recent.length == max) break;
  }
  return recent;
}

/// The commands of [found] and the built-ins that match [query], in the
/// menu's order. Names that start with it come first, then names with a
/// part after a colon that starts with it, then names that contain it;
/// within each, the [recent] ones (latest first), then the rest in the
/// order of [found] and the built-ins. A recent command shows only while
/// it is known: one that went, or a picker that is left out, does not.
List<SlashCommand> slashMatches(
  String query,
  List<SlashCommand> found, {
  List<String> recent = const [],
}) {
  final q = query.toLowerCase();
  final seen = <String>{};
  final all = [
    for (final c in [...found, ...builtInSlashCommands])
      if (seen.add(c.name)) c,
  ];
  int? bucket(SlashCommand c) {
    final name = c.name.toLowerCase();
    if (name.startsWith(q)) return 0;
    if (name.split(':').skip(1).any((p) => p.startsWith(q))) return 1;
    if (name.contains(q)) return 2;
    return null;
  }

  int rank(SlashCommand c) {
    final i = recent.indexOf(c.name);
    return i < 0 ? recent.length : i;
  }

  final matches = [
    for (final (i, c) in all.indexed)
      if (bucket(c) case final b?) (b, rank(c), i, c),
  ];
  matches.sort((a, b) {
    final byBucket = a.$1.compareTo(b.$1);
    if (byBucket != 0) return byBucket;
    final byRecent = a.$2.compareTo(b.$2);
    if (byRecent != 0) return byRecent;
    return a.$3.compareTo(b.$3);
  });
  return [for (final m in matches) m.$4];
}

/// The commands that a lookup found, for one screen. Reads again when the
/// menu wants them for another directory, or after [maxAge]; one read at a
/// time. A read for another directory starts with none found. A failed read keeps what was found for the same directory, and is
/// tried again after [maxAge].
class SlashCommands extends ChangeNotifier {
  SlashCommands({
    this.maxAge = const Duration(minutes: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final Duration maxAge;
  final DateTime Function() _now;

  var _found = const <SlashCommand>[];
  var _loading = false;
  var _failed = false;
  var _disposed = false;
  DateTime? _at;
  String? _cwd;

  /// What the last read found; empty before it.
  List<SlashCommand> get found => _found;

  /// A read runs.
  bool get loading => _loading;

  /// The last read failed.
  bool get failed => _failed;

  /// Starts a read with [lookup] unless one runs, or the last one for
  /// [cwd] is younger than [maxAge]. Without [lookup], as with no link,
  /// it does nothing.
  void want(SlashCommandLookup? lookup, String? cwd) {
    if (lookup == null || _loading || _disposed) return;
    final at = _at;
    if (at != null && _cwd == cwd && _now().difference(at) < maxAge) return;
    _loading = true;
    // Another directory's project commands are not this one's.
    if (_cwd != cwd) _found = const [];
    notifyListeners();
    unawaited(_load(lookup, cwd));
  }

  Future<void> _load(SlashCommandLookup lookup, String? cwd) async {
    try {
      final found = await lookup(cwd);
      if (_disposed) return;
      _found = List.unmodifiable(found);
      _failed = false;
    } catch (e) {
      if (_disposed) return;
      debugPrint('shellherd: slash command lookup failed: $e');
      _failed = true;
    }
    _at = _now();
    _cwd = cwd;
    _loading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
