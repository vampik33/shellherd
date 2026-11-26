/// What the chat view shows: one entry per prompt, reply, thought, tool
/// call or note of an agent's conversation.
library;

sealed class ChatItem {
  const ChatItem();
}

/// An item that is only its text.
sealed class _TextItem extends ChatItem {
  const _TextItem(this.text);
  final String text;

  @override
  bool operator ==(Object other) =>
      other.runtimeType == runtimeType && (other as _TextItem).text == text;

  @override
  int get hashCode => Object.hash(runtimeType, text);

  @override
  String toString() => '$runtimeType($text)';
}

/// What the user typed: a prompt, a slash command or a `!` command.
class ChatPrompt extends _TextItem {
  const ChatPrompt(super.text);
}

/// Text of the agent, in markdown.
class ChatReply extends _TextItem {
  const ChatReply(super.text);
}

/// The agent's thinking; empty where the transcript keeps none of it.
class ChatThinking extends _TextItem {
  const ChatThinking(super.text);
}

/// A tool the agent called, and its result once there is one.
class ChatTool extends ChatItem {
  const ChatTool({
    required this.id,
    required this.name,
    required this.summary,
    required this.input,
    this.result,
  });

  final String id;
  final String name;

  /// One line that says what the call does, such as the file or command.
  final String summary;

  /// The whole input, for the expanded row.
  final String input;

  /// Null while the tool runs or waits for permission.
  final ToolResult? result;

  ChatTool withResult(ToolResult result) => ChatTool(
    id: id,
    name: name,
    summary: summary,
    input: input,
    result: result,
  );

  @override
  bool operator ==(Object other) =>
      other is ChatTool &&
      other.id == id &&
      other.name == name &&
      other.summary == summary &&
      other.input == input &&
      other.result == result;

  @override
  int get hashCode => Object.hash(id, name, summary, input, result);

  @override
  String toString() => 'ChatTool($name: $summary, $result)';
}

class ToolResult {
  const ToolResult(this.text, {required this.isError});
  final String text;
  final bool isError;

  @override
  bool operator ==(Object other) =>
      other is ToolResult && other.text == text && other.isError == isError;

  @override
  int get hashCode => Object.hash(text, isError);

  @override
  String toString() => 'ToolResult(${isError ? 'error: ' : ''}$text)';
}

/// Something that happened in the conversation, such as an interrupt or the
/// output of a slash command.
class ChatNote extends _TextItem {
  const ChatNote(super.text);
}
