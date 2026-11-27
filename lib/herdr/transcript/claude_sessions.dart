import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../../ssh/ssh_exec.dart';
import 'transcript_command.dart';

/// What Claude Code calls itself in its OSC 7501 status reports, which
/// herdr-core passes on as the terminal's `status.app`.
const claudeCodeApp = 'claude-code';

/// Finds the Claude Code session of each process in [pids] on the remote
/// host; a process without one is left out.
typedef ClaudeSessionLookup = Future<Map<int, String>> Function(List<int> pids);

/// Marks each line of [claudeSessionsCommand]'s output. Lines before it
/// come from the remote shell's startup files.
const claudeSessionMarker = 'shellherd-claude-session ';

/// The longest session file that is read; Claude Code's are under 1 KiB.
const _maxSessionFile = 64 * 1024;

/// Prints, for each process in [pids] that has a Claude Code session file
/// (`<config>/sessions/<pid>.json`, the config directory in
/// CLAUDE_CONFIG_DIR or `~/.claude`), one line: [claudeSessionMarker], the
/// pid and the file's JSON with its newlines dropped. Claude Code writes
/// that file for each interactive session and rewrites it when `/clear`
/// or `/resume` changes the session. The file is internal to Claude
/// Code: where it is missing, the pane shows its text.
///
/// Through `sh`, because the login shell can be fish.
String claudeSessionsCommand(List<int> pids) {
  if (pids.isEmpty || pids.any((p) => p <= 0)) {
    throw ArgumentError.value(pids, 'pids', 'not process ids');
  }
  final inner = [
    'd="$claudeConfigDir/sessions"',
    'for p in ${pids.join(' ')}; do',
    '  f="\$d/\$p.json"',
    '  [ -r "\$f" ] || continue',
    '  printf "%s%s " "$claudeSessionMarker" "\$p"',
    "  head -c $_maxSessionFile \"\$f\" | tr -d '\\n\\r'",
    '  echo',
    'done',
  ].join('\n');
  return 'sh -c ${shQuote(inner)}';
}

/// The sessions in [output] of [claudeSessionsCommand] for [pids]. A line
/// counts only for a pid that was asked for, whose file is a JSON object
/// that names the same pid and a session id that [claudeSessionId] takes.
Map<int, String> parseClaudeSessions(String output, Iterable<int> pids) {
  final asked = pids.toSet();
  final sessions = <int, String>{};
  for (final line in const LineSplitter().convert(output)) {
    final at = line.indexOf(claudeSessionMarker);
    if (at < 0) continue;
    final rest = line.substring(at + claudeSessionMarker.length);
    final space = rest.indexOf(' ');
    if (space < 0) continue;
    final pid = int.tryParse(rest.substring(0, space));
    if (pid == null || !asked.contains(pid)) continue;
    final Object? json;
    try {
      json = jsonDecode(rest.substring(space + 1));
    } on FormatException {
      continue;
    }
    if (json is! Map<String, Object?> || json['pid'] != pid) continue;
    final session = json['sessionId'];
    if (session is String && claudeSessionId.hasMatch(session)) {
      sessions[pid] = session;
    }
  }
  return sessions;
}

/// A [ClaudeSessionLookup] that runs [claudeSessionsCommand] on the remote
/// host, on its own bounded exec channel.
ClaudeSessionLookup sshClaudeSessionLookup(
  SSHClient ssh, {
  Duration timeout = const Duration(seconds: 15),
}) => (pids) async {
  final (out, code) = await sshExec(ssh, claudeSessionsCommand(pids), timeout);
  if (code != 0) {
    throw ExecFailed('Claude Code session lookup', code ?? -1, out.trim());
  }
  return parseClaudeSessions(out, pids);
};

/// The Claude Code sessions of the agents of one link to the Herdr app, by
/// the pid of the process in front of their terminal.
///
/// [want] names the pids to know. A pid is looked up when it first comes,
/// then again every [refreshEvery] while it stays wanted: `/clear` and
/// `/resume` start a new session in the same process, and nothing tells of
/// that. [onChange] runs when [known] changed by a lookup. A failed lookup
/// keeps what was known and tries again at the next refresh.
class ClaudeSessions {
  ClaudeSessions(
    this._lookup, {
    required this.onChange,
    this.refreshEvery = const Duration(seconds: 15),
  }) {
    _timer = Timer.periodic(refreshEvery, (_) => unawaited(_run(all: true)));
  }

  final ClaudeSessionLookup _lookup;
  final void Function() onChange;
  final Duration refreshEvery;

  late final Timer _timer;
  final _known = <int, String>{};
  var _wanted = <int>{};

  /// Pids looked up, or being looked up, since they became wanted.
  final _asked = <int>{};
  var _busy = false;
  var _closed = false;

  /// The session of each wanted pid that has one.
  Map<int, String> get known => UnmodifiableMapView(_known);

  /// Sets the pids to know; drops the others, and looks up new ones.
  void want(Set<int> pids) {
    if (_closed) return;
    _wanted = {...pids};
    _known.removeWhere((pid, _) => !_wanted.contains(pid));
    _asked.removeWhere((pid) => !_wanted.contains(pid));
    if (_wanted.any((pid) => !_asked.contains(pid))) unawaited(_run());
  }

  /// Looks up the wanted pids not asked yet, or with [all] every wanted
  /// pid; then the pids that became wanted meanwhile. One lookup at a time:
  /// a refresh that comes during one waits for the next.
  Future<void> _run({bool all = false}) async {
    if (_busy || _closed) return;
    _busy = true;
    try {
      while (!_closed) {
        final pids = [
          for (final pid in _wanted)
            if (all || !_asked.contains(pid)) pid,
        ]..sort();
        all = false;
        if (pids.isEmpty) return;
        _asked.addAll(pids);
        final Map<int, String> found;
        try {
          found = await _lookup(pids);
        } catch (e) {
          debugPrint('shellherd: Claude Code session lookup failed: $e');
          return;
        }
        if (_closed) return;
        var changed = false;
        for (final pid in pids) {
          if (!_wanted.contains(pid)) continue;
          final session = found[pid];
          if (_known[pid] == session) continue;
          changed = true;
          if (session == null) {
            _known.remove(pid);
          } else {
            _known[pid] = session;
          }
        }
        if (changed) onChange();
      }
    } finally {
      _busy = false;
    }
  }

  void close() {
    _closed = true;
    _timer.cancel();
  }
}
