import 'dart:convert';

import 'chat_items.dart';

/// Turns the lines of a Claude Code transcript (JSONL, one record a line)
/// into [ChatItem]s, one line at a time.
///
/// The format is Claude Code's own and undocumented, so only the shapes
/// read here are kept and anything else is dropped: a new kind of record
/// can hide itself, never break the chat. Each content block of a reply is
/// its own record, sharing the reply's message id; they come in order, so
/// each becomes the next item. A record seen twice (by its uuid), a
/// subagent's records (`isSidechain`) and the text Claude Code adds for
/// the model (`isMeta`) are dropped.
///
/// It keeps what each record says, so that [prepend] can put earlier lines
/// in front. Each item has a key ([keys]) that stays with it as earlier
/// lines go in front: a tool call's id, or the record's uuid (a number for
/// a record without one) and where the item stands in it.
class ClaudeTranscript {
  /// What each line read said, oldest first, while [keepRecords].
  final _records = <_Record>[];

  /// Whether it keeps what each line said, for [prepend]. Turning it off
  /// drops what it kept.
  bool get keepRecords => _keepRecords;
  set keepRecords(bool value) {
    _keepRecords = value;
    if (!value) _records.clear();
  }

  var _keepRecords = true;

  final _items = <ChatItem>[];
  final _keys = <Object>[];

  /// The numbers of the records without a uuid: the next one added, and
  /// the first one in front.
  var _next = 0;
  var _first = 0;

  /// Where each tool call stands in [_items], by its id.
  final _toolAt = <String, int>{};
  final _seen = <String>{};

  /// The items so far, oldest first.
  List<ChatItem> get items => List.unmodifiable(_items);

  /// A key for each of [items], none twice.
  List<Object> get keys => List.unmodifiable(_keys);

  /// Reads one line. A line that is no record, such as a cut-off one, is
  /// dropped.
  void add(String line) {
    final parsed = _parse(line);
    if (parsed == null) return;
    final record = (uuid: parsed.uuid, number: _next++, events: parsed.events);
    if (_keepRecords) _records.add(record);
    _apply(record);
  }

  /// Reads [lines], the lines of the file just before those read so far,
  /// oldest first. The items are then the same as if [lines] had been read
  /// first. Returns how many items come before those of the lines read
  /// before. Needs [keepRecords]; throws [StateError] without.
  int prepend(Iterable<String> lines) {
    if (!_keepRecords) throw StateError('no records kept to prepend to');
    final parsed = [for (final line in lines) ?_parse(line)];
    if (parsed.isEmpty) return 0;
    _first -= parsed.length;
    final earlier = [
      for (final (i, p) in parsed.indexed)
        (uuid: p.uuid, number: _first + i, events: p.events),
    ];
    _records.insertAll(0, earlier);
    _items.clear();
    _keys.clear();
    _toolAt.clear();
    _seen.clear();
    for (final record in earlier) {
      _apply(record);
    }
    final before = _items.length;
    for (final record in _records.skip(earlier.length)) {
      _apply(record);
    }
    return before;
  }

  /// What [line] says; null for a line that is no record this reads.
  static _Parsed? _parse(String line) {
    if (!line.startsWith('{')) return null;
    final Object? json;
    try {
      json = jsonDecode(line);
    } on FormatException {
      return null;
    }
    if (json is! Map<String, Object?>) return null;
    if (json['isSidechain'] == true || json['isMeta'] == true) return null;
    final type = json['type'];
    if (type != 'user' && type != 'assistant') return null;
    final message = json['message'];
    if (message is! Map<String, Object?>) return null;
    final uuid = json['uuid'];
    final content = message['content'];
    final events = <_Event>[];
    if (type == 'assistant') {
      _assistant(content, events, apiError: json['isApiErrorMessage'] == true);
    } else if (json['isCompactSummary'] == true) {
      events.add(const _Item(ChatNote('Earlier conversation was summarized.')));
    } else {
      _user(content, events);
    }
    // A record without items still counts as seen by its uuid.
    if (uuid is! String && events.isEmpty) return null;
    return (uuid: uuid is String ? uuid : null, events: events);
  }

  void _apply(_Record record) {
    final uuid = record.uuid;
    if (uuid != null && !_seen.add(uuid)) return;
    for (final (at, event) in record.events.indexed) {
      switch (event) {
        case _Item(:final item):
          _items.add(item);
          _keys.add(uuid != null ? (uuid, at) : (record.number, at));
        case _Tool(:final tool):
          if (_toolAt.containsKey(tool.id)) continue;
          _toolAt[tool.id] = _items.length;
          _items.add(tool);
          _keys.add(('tool', tool.id));
        case _Result(:final id, :final result):
          final at = _toolAt[id];
          // The call was before the part of the transcript that was read.
          if (at == null) continue;
          _items[at] = (_items[at] as ChatTool).withResult(result);
      }
    }
  }

  static void _user(Object? content, List<_Event> events) {
    if (content is String) return _userText(content, events);
    if (content is! List<Object?>) return;
    final text = <String>[];
    for (final block in content.whereType<Map<String, Object?>>()) {
      switch (block['type']) {
        case 'text':
          if (block['text'] case final String t) text.add(t);
        case 'image':
          text.add('[image]');
        case 'tool_result':
          _toolResult(block, events);
      }
    }
    if (text.isNotEmpty) _userText(text.join('\n'), events);
  }

  static void _userText(String text, List<_Event> events) {
    final item = _userItem(text);
    if (item != null) events.add(_Item(item));
  }

  static ChatItem? _userItem(String text) {
    if (text.trim().isEmpty) return null;
    if (text.startsWith('[Request interrupted by user')) {
      return const ChatNote('Interrupted');
    }
    // Claude Code's own records start with its tags; a typed prompt that
    // only mentions one is a prompt.
    switch (_leadTag.firstMatch(text.trimLeft())?[1]) {
      case 'command-name' || 'command-message':
        if (_tag(text, 'command-name') case final name?) {
          final args = _tag(text, 'command-args') ?? '';
          return ChatPrompt('$name $args'.trim());
        }
      case 'local-command-stdout':
        if (_tag(text, 'local-command-stdout') case final out?) {
          return _note(out);
        }
      case 'local-command-caveat':
        if (_tag(text, 'local-command-caveat') != null) return null;
      case 'bash-input':
        if (_tag(text, 'bash-input') case final command?) {
          return ChatPrompt('! $command');
        }
      case 'bash-stdout' || 'bash-stderr':
        final stdout = _tag(text, 'bash-stdout');
        final stderr = _tag(text, 'bash-stderr');
        if (stdout != null || stderr != null) {
          return _note(
            [?stdout, ?stderr].where((s) => s.trim().isNotEmpty).join('\n'),
          );
        }
    }
    return ChatPrompt(text.trim());
  }

  /// A note of command output; null when it is empty.
  static ChatNote? _note(String output) {
    final shown = stripAnsi(output).trim();
    return shown.isEmpty ? null : ChatNote(shown);
  }

  static void _toolResult(Map<String, Object?> block, List<_Event> events) {
    final id = block['tool_use_id'];
    if (id is! String) return;
    events.add(
      _Result(
        id,
        ToolResult(
          _cap(stripAnsi(_resultText(block['content']))),
          isError: block['is_error'] == true,
        ),
      ),
    );
  }

  static void _assistant(
    Object? content,
    List<_Event> events, {
    required bool apiError,
  }) {
    if (content is! List<Object?>) return;
    for (final block in content.whereType<Map<String, Object?>>()) {
      switch (block['type']) {
        case 'text':
          final text = block['text'];
          if (text is! String || text.trim().isEmpty) continue;
          events.add(
            _Item(apiError ? ChatNote(text.trim()) : ChatReply(text.trim())),
          );
        case 'thinking':
          final text = block['thinking'];
          events.add(_Item(ChatThinking(text is String ? text.trim() : '')));
        case 'redacted_thinking':
          events.add(const _Item(ChatThinking('')));
        case 'tool_use':
          final id = block['id'];
          final name = block['name'];
          if (id is! String || name is! String) continue;
          final input = switch (block['input']) {
            final Map<String, Object?> m => m,
            _ => const <String, Object?>{},
          };
          events.add(
            _Tool(
              ChatTool(
                id: id,
                name: name,
                summary: toolSummary(name, input),
                input: _cap(_inputText(name, input)),
              ),
            ),
          );
      }
    }
  }
}

/// What one line of a transcript says: its uuid, and what it adds to the
/// chat, in order.
typedef _Parsed = ({String? uuid, List<_Event> events});

/// A line read, with its number among the lines read.
typedef _Record = ({String? uuid, int number, List<_Event> events});

sealed class _Event {
  const _Event();
}

/// An item that is not a tool call.
class _Item extends _Event {
  const _Item(this.item);
  final ChatItem item;
}

/// A tool call, unless one with its id came before.
class _Tool extends _Event {
  const _Tool(this.tool);
  final ChatTool tool;
}

/// The result of the tool call [id], if that call was read.
class _Result extends _Event {
  const _Result(this.id, this.result);
  final String id;
  final ToolResult result;
}

/// The longest text a tool row keeps of an input or a result.
const toolTextCap = 4000;

String _cap(String text) => text.length <= toolTextCap
    ? text
    : '${text.substring(0, toolTextCap)}\n… (${text.length - toolTextCap} '
          'more characters)';

/// The text of a tool result: a string, or a list of text and image blocks.
String _resultText(Object? content) => switch (content) {
  final String s => s,
  final List<Object?> blocks => [
    for (final b in blocks.whereType<Map<String, Object?>>())
      if (b['text'] case final String text when b['type'] == 'text')
        text
      else if (b['type'] == 'image')
        '[image]',
  ].join('\n'),
  _ => '',
};

String _inputText(String name, Map<String, Object?> input) {
  if (name == 'Bash' && input['command'] is String) {
    return input['command']! as String;
  }
  return const JsonEncoder.withIndent('  ').convert(input);
}

/// One line that says what a call of tool [name] with [input] does.
String toolSummary(String name, Map<String, Object?> input) {
  String? field(String key) => switch (input[key]) {
    final String s when s.trim().isNotEmpty => s.trim(),
    _ => null,
  };
  final summary = switch (name) {
    'Bash' => field('description') ?? field('command'),
    'Read' || 'Write' || 'Edit' || 'MultiEdit' => field('file_path'),
    'NotebookEdit' => field('notebook_path'),
    'Grep' || 'Glob' => field('pattern'),
    'WebFetch' => field('url'),
    'WebSearch' => field('query'),
    'Task' || 'Agent' => field('description'),
    'AskUserQuestion' => switch (input['questions']) {
      [{'question': final String q}, ...] => q,
      _ => null,
    },
    _ => null,
  };
  final line =
      summary ??
      input.values
          .whereType<String>()
          .where((s) => s.trim().isNotEmpty)
          .firstOrNull
          ?.trim() ??
      '';
  return line.split('\n').first;
}

/// The text of [tag] in [text], between its first open and close; null
/// when it has none.
String? _tag(String text, String tag) {
  final open = text.indexOf('<$tag>');
  if (open < 0) return null;
  final start = open + tag.length + 2;
  final close = text.indexOf('</$tag>', start);
  return close < 0 ? null : text.substring(start, close);
}

/// The tag a text starts with, such as `bash-input`.
final _leadTag = RegExp(r'^<([a-z-]+)>');

final _ansi = RegExp(r'\x1b\[[0-9;:<=>?]*[ -/]*[@-~]|\x1b');

/// [text] without terminal escape sequences.
String stripAnsi(String text) => text.replaceAll(_ansi, '');
