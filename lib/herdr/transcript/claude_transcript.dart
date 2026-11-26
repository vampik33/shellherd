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
class ClaudeTranscript {
  final _items = <ChatItem>[];

  /// Where each tool call stands in [_items], by its id.
  final _toolAt = <String, int>{};
  final _seen = <String>{};

  /// The items so far, oldest first.
  List<ChatItem> get items => List.unmodifiable(_items);

  /// Reads one line. A line that is no record, such as a cut-off one, is
  /// dropped.
  void add(String line) {
    if (!line.startsWith('{')) return;
    final Object? json;
    try {
      json = jsonDecode(line);
    } on FormatException {
      return;
    }
    if (json is! Map<String, Object?>) return;
    if (json['isSidechain'] == true || json['isMeta'] == true) return;
    final type = json['type'];
    if (type != 'user' && type != 'assistant') return;
    final message = json['message'];
    if (message is! Map<String, Object?>) return;
    final uuid = json['uuid'];
    if (uuid is String && !_seen.add(uuid)) return;
    final content = message['content'];
    if (type == 'assistant') {
      _assistant(content, apiError: json['isApiErrorMessage'] == true);
    } else if (json['isCompactSummary'] == true) {
      _items.add(const ChatNote('Earlier conversation was summarized.'));
    } else {
      _user(content);
    }
  }

  void _user(Object? content) {
    if (content is String) return _userText(content);
    if (content is! List<Object?>) return;
    final text = <String>[];
    for (final block in content.whereType<Map<String, Object?>>()) {
      switch (block['type']) {
        case 'text':
          if (block['text'] case final String t) text.add(t);
        case 'image':
          text.add('[image]');
        case 'tool_result':
          _toolResult(block);
      }
    }
    if (text.isNotEmpty) _userText(text.join('\n'));
  }

  void _userText(String text) {
    if (text.trim().isEmpty) return;
    if (text.startsWith('[Request interrupted by user')) {
      _items.add(const ChatNote('Interrupted'));
      return;
    }
    // Claude Code's own records start with its tags; a typed prompt that
    // only mentions one is a prompt.
    switch (_leadTag.firstMatch(text.trimLeft())?[1]) {
      case 'command-name' || 'command-message':
        if (_tag(text, 'command-name') case final name?) {
          final args = _tag(text, 'command-args') ?? '';
          _items.add(ChatPrompt('$name $args'.trim()));
          return;
        }
      case 'local-command-stdout':
        if (_tag(text, 'local-command-stdout') case final out?) {
          _note(out);
          return;
        }
      case 'local-command-caveat':
        if (_tag(text, 'local-command-caveat') != null) return;
      case 'bash-input':
        if (_tag(text, 'bash-input') case final command?) {
          _items.add(ChatPrompt('! $command'));
          return;
        }
      case 'bash-stdout' || 'bash-stderr':
        final stdout = _tag(text, 'bash-stdout');
        final stderr = _tag(text, 'bash-stderr');
        if (stdout != null || stderr != null) {
          _note(
            [?stdout, ?stderr].where((s) => s.trim().isNotEmpty).join('\n'),
          );
          return;
        }
    }
    _items.add(ChatPrompt(text.trim()));
  }

  /// A note of command output, unless it is empty.
  void _note(String output) {
    final shown = stripAnsi(output).trim();
    if (shown.isNotEmpty) _items.add(ChatNote(shown));
  }

  void _toolResult(Map<String, Object?> block) {
    final id = block['tool_use_id'];
    final at = id is String ? _toolAt[id] : null;
    // The call was before the part of the transcript that was read.
    if (at == null) return;
    final tool = _items[at] as ChatTool;
    _items[at] = tool.withResult(
      ToolResult(
        _cap(stripAnsi(_resultText(block['content']))),
        isError: block['is_error'] == true,
      ),
    );
  }

  void _assistant(Object? content, {required bool apiError}) {
    if (content is! List<Object?>) return;
    for (final block in content.whereType<Map<String, Object?>>()) {
      switch (block['type']) {
        case 'text':
          final text = block['text'];
          if (text is! String || text.trim().isEmpty) continue;
          _items.add(apiError ? ChatNote(text.trim()) : ChatReply(text.trim()));
        case 'thinking':
          final text = block['thinking'];
          _items.add(ChatThinking(text is String ? text.trim() : ''));
        case 'redacted_thinking':
          _items.add(const ChatThinking(''));
        case 'tool_use':
          final id = block['id'];
          final name = block['name'];
          if (id is! String || name is! String || _toolAt.containsKey(id)) {
            continue;
          }
          final input = switch (block['input']) {
            final Map<String, Object?> m => m,
            _ => const <String, Object?>{},
          };
          _toolAt[id] = _items.length;
          _items.add(
            ChatTool(
              id: id,
              name: name,
              summary: toolSummary(name, input),
              input: _cap(_inputText(name, input)),
            ),
          );
      }
    }
  }
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
