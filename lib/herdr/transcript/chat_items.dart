/// What the chat view shows: one entry per prompt, reply, thought, tool
/// call or note of an agent's conversation.
library;

sealed class ChatItem {
  const ChatItem();
}

/// What the user typed: a prompt, a slash command or a `!` command.
class ChatPrompt extends ChatItem {
  const ChatPrompt(this.text);
  final String text;

  @override
  bool operator ==(Object other) => other is ChatPrompt && other.text == text;

  @override
  int get hashCode => Object.hash(ChatPrompt, text);

  @override
  String toString() => 'ChatPrompt($text)';
}

/// Text of the agent, in markdown.
class ChatReply extends ChatItem {
  const ChatReply(this.text);
  final String text;

  @override
  bool operator ==(Object other) => other is ChatReply && other.text == text;

  @override
  int get hashCode => Object.hash(ChatReply, text);

  @override
  String toString() => 'ChatReply($text)';
}

/// The agent's thinking; empty where the transcript keeps none of it.
class ChatThinking extends ChatItem {
  const ChatThinking(this.text);
  final String text;

  @override
  bool operator ==(Object other) => other is ChatThinking && other.text == text;

  @override
  int get hashCode => Object.hash(ChatThinking, text);

  @override
  String toString() => 'ChatThinking($text)';
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
class ChatNote extends ChatItem {
  const ChatNote(this.text);
  final String text;

  @override
  bool operator ==(Object other) => other is ChatNote && other.text == text;

  @override
  int get hashCode => Object.hash(ChatNote, text);

  @override
  String toString() => 'ChatNote($text)';
}
