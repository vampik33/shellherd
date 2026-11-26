import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ui/palette.dart';
import '../api/herdr_client.dart';
import '../transcript/chat_items.dart';
import 'herdr_lists.dart';

const _monoStyle = TextStyle(fontFamily: monoFont, fontSize: 12, height: 1.35);

/// An agent's conversation as a chat: the user's prompts in bubbles on the
/// right, the agent's replies in markdown on the left, its tool calls as
/// rows that open on a tap. The newest is at the bottom. While the user
/// reads further up, the chat stays still. Without [showDetails], thinking
/// and tool calls are left out.
class ChatView extends StatefulWidget {
  const ChatView({
    super.key,
    required this.items,
    this.startsCut = false,
    this.status,
    this.showDetails = true,
  });

  final List<ChatItem> items;

  /// Older messages were not read: the top says so.
  final bool startsCut;

  /// The agent's state, for the line under the last message.
  final AgentStatus? status;

  /// Shows the agent's thinking and tool calls.
  final bool showDetails;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final _scroll = ScrollController();
  late List<ChatItem> _shown;

  bool get _scrolledUp => _scroll.hasClients && _scroll.offset > 1;

  @override
  void initState() {
    super.initState();
    _shown = widget.items;
    _scroll.addListener(_release);
  }

  @override
  void didUpdateWidget(ChatView old) {
    super.didUpdateWidget(old);
    if (!_scrolledUp) _shown = widget.items;
  }

  void _release() {
    if (identical(_shown, widget.items) || _scrolledUp) return;
    setState(() => _shown = widget.items);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = _shown;
    // The places in [items] of the rows shown, oldest first; null for all.
    final shown = widget.showDetails
        ? null
        : [
            for (var at = 0; at < items.length; at++)
              if (items[at] is! ChatThinking && items[at] is! ChatTool) at,
          ];
    final rows = shown?.length ?? items.length;
    int place(int row) => shown?[row] ?? row;
    final working = widget.status == AgentStatus.working;
    if (rows == 0 && !widget.startsCut && !working) {
      return const Center(
        child: Text('No messages yet.', style: TextStyle(color: Graphite.dim)),
      );
    }
    // The list runs from the bottom: index 0 is the working line, when
    // there is one, then the newest item. Items keep the key of their
    // place from the top, so that a row stays open as new ones come; tool
    // calls the key of their id, so that one stays open when a new read
    // starts at another record.
    final lead = working ? 1 : 0;
    final count = lead + rows + (widget.startsCut ? 1 : 0);
    // Built on the first lookup of a tool call's key only.
    Map<Key, int>? toolAt;
    // The row of each place, built on the first lookup with rows left out.
    Map<int, int>? rowOf;
    final markdown = _markdownStyle(Theme.of(context));
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      itemCount: count,
      findChildIndexCallback: (key) {
        final at = switch (key) {
          ValueKey<int>(:final value)
              when value < items.length && items[value] is! ChatTool =>
            value,
          ValueKey<int>() => null,
          _ => (toolAt ??= {
            for (var at = 0; at < items.length; at++)
              if (items[at] is ChatTool) _key(items, at): at,
          })[key],
        };
        if (at == null) return null;
        final row = shown == null
            ? at
            : (rowOf ??= {for (final (row, at) in shown.indexed) at: row})[at];
        return row == null ? null : lead + rows - 1 - row;
      },
      itemBuilder: (context, i) {
        if (i < lead) return const _Working();
        final row = rows - 1 - (i - lead);
        if (row < 0) {
          return const _Note('Earlier messages are not shown.');
        }
        final at = place(row);
        return KeyedSubtree(
          key: _key(items, at),
          child: _row(
            items[at],
            previous: row > 0 ? items[place(row - 1)] : null,
            markdown: markdown,
          ),
        );
      },
    );
  }

  static Key _key(List<ChatItem> items, int at) => switch (items[at]) {
    ChatTool(:final id) => ValueKey(('tool', id)),
    _ => ValueKey(at),
  };

  Widget _row(
    ChatItem item, {
    ChatItem? previous,
    required MarkdownStyleSheet markdown,
  }) {
    // More room above a new turn than between the parts of one.
    final turnStart = item is ChatPrompt || previous is ChatPrompt;
    return Padding(
      padding: EdgeInsets.only(top: turnStart ? 14 : 4),
      child: switch (item) {
        ChatPrompt(:final text) => _Prompt(text),
        ChatReply(:final text) => _Reply(text, markdown),
        ChatThinking(:final text) => _Thinking(text),
        final ChatTool tool => _ToolRow(tool),
        ChatNote(:final text) => _Note(text),
      },
    );
  }
}

/// The user's prompt: a bubble on the right.
class _Prompt extends StatelessWidget {
  const _Prompt(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.85,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Graphite.raised,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: SelectableText(
            text,
            style: const TextStyle(fontSize: 15, color: Graphite.foreground),
          ),
        ),
      ),
    ),
  );
}

/// The agent's text, in markdown, across the width.
class _Reply extends StatelessWidget {
  const _Reply(this.text, this.style);
  final String text;
  final MarkdownStyleSheet style;

  @override
  Widget build(BuildContext context) => MarkdownBody(
    data: text,
    selectable: true,
    styleSheet: style,
    onTapLink: (_, href, _) => _openLink(href),
    // Agent text must not make the phone fetch an image from anywhere.
    imageBuilder: (uri, _, alt) => Text(
      '[image: ${alt ?? uri}]',
      style: const TextStyle(color: Graphite.muted),
    ),
  );
}

/// Opens a web link of a reply in the browser; other schemes stay closed.
void _openLink(String? href) {
  final uri = href == null ? null : Uri.tryParse(href);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return;
  launchUrl(uri, mode: LaunchMode.externalApplication).catchError((Object e) {
    debugPrint('shellherd: cannot open $uri: $e');
    return false;
  });
}

/// Markdown in Herdr app's graphite: Geist for prose, JetBrains Mono for
/// code, its blocks on the chrome colour.
MarkdownStyleSheet _markdownStyle(ThemeData theme) {
  const body = TextStyle(
    fontFamily: uiFont,
    fontSize: 15,
    height: 1.45,
    color: Graphite.foreground,
  );
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: body,
    a: body.copyWith(color: Graphite.accent),
    strong: const TextStyle(fontWeight: FontWeight.w600),
    listBullet: body,
    h1: body.copyWith(fontSize: 20, fontWeight: FontWeight.w600),
    h2: body.copyWith(fontSize: 18, fontWeight: FontWeight.w600),
    h3: body.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
    h4: body.copyWith(fontWeight: FontWeight.w600),
    // No background: flutter_markdown_plus draws the inline code style in
    // code blocks too, line by line.
    code: const TextStyle(
      fontFamily: monoFont,
      fontSize: 13,
      color: Graphite.cyan,
    ),
    codeblockPadding: const EdgeInsets.all(10),
    codeblockDecoration: BoxDecoration(
      color: Graphite.chrome,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: Graphite.border),
    ),
    blockquote: body.copyWith(color: Graphite.muted),
    blockquoteDecoration: const BoxDecoration(
      border: Border(left: BorderSide(color: Graphite.dim, width: 3)),
    ),
    tableHead: body.copyWith(fontWeight: FontWeight.w600),
    tableBody: body,
    tableBorder: TableBorder.all(color: Graphite.border),
    horizontalRuleDecoration: const BoxDecoration(
      border: Border(top: BorderSide(color: Graphite.border)),
    ),
  );
}

/// A row that shows [header] and opens on a tap to show [body].
class _Expandable extends StatefulWidget {
  const _Expandable({required this.header, this.body});

  final Widget header;

  /// Null for a row with nothing more to show.
  final Widget? body;

  @override
  State<_Expandable> createState() => _ExpandableState();
}

class _ExpandableState extends State<_Expandable> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final body = widget.body;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: body == null ? null : () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(child: widget.header),
                if (body != null)
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: Graphite.dim,
                  ),
              ],
            ),
          ),
        ),
        if (_open && body != null)
          Padding(padding: const EdgeInsets.only(top: 4), child: body),
      ],
    );
  }
}

/// The agent's thinking: a faint row, its text on a tap.
class _Thinking extends StatelessWidget {
  const _Thinking(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => _Expandable(
    header: const Row(
      children: [
        Icon(Icons.psychology_outlined, size: 16, color: Graphite.dim),
        SizedBox(width: 8),
        Text(
          'Thinking',
          style: TextStyle(color: Graphite.dim, fontStyle: FontStyle.italic),
        ),
      ],
    ),
    body: text.isEmpty
        ? null
        : SelectableText(
            text,
            style: const TextStyle(
              color: Graphite.muted,
              fontStyle: FontStyle.italic,
              height: 1.4,
            ),
          ),
  );
}

/// A tool call: its name and what it works on, and on a tap its input and
/// result.
class _ToolRow extends StatelessWidget {
  const _ToolRow(this.tool);
  final ChatTool tool;

  @override
  Widget build(BuildContext context) {
    final result = tool.result;
    return _Expandable(
      header: Row(
        children: [
          _toolStateIcon(tool),
          const SizedBox(width: 8),
          Text(
            tool.name,
            style: _monoStyle.copyWith(
              color: Graphite.foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              tool.summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _monoStyle.copyWith(color: Graphite.muted),
            ),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ToolText(tool.input),
          if (result != null && result.text.isNotEmpty) ...[
            const SizedBox(height: 4),
            _ToolText(result.text, error: result.isError),
          ],
        ],
      ),
    );
  }
}

/// Whether [tool] runs, worked or failed.
Widget _toolStateIcon(ChatTool tool) => switch (tool.result) {
  null => const StatusDot(AgentStatus.working),
  ToolResult(isError: false) => const Icon(
    Icons.check,
    size: 16,
    color: Graphite.green,
  ),
  ToolResult(isError: true) => const Icon(
    Icons.close,
    size: 16,
    color: Graphite.red,
  ),
};

/// The input or result of a tool, in a code block.
class _ToolText extends StatelessWidget {
  const _ToolText(this.text, {this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: error ? Graphite.errorContainer : Graphite.chrome,
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: Graphite.border),
    ),
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: SelectableText(
        text,
        style: _monoStyle.copyWith(color: Graphite.terminalForeground),
      ),
    ),
  );
}

/// Something that happened, in small faint text in the middle.
class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Text(
      text,
      textAlign: TextAlign.center,
      maxLines: 12,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(fontSize: 12, color: Graphite.dim),
    ),
  );
}

/// Under the last message while the agent works.
class _Working extends StatelessWidget {
  const _Working();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(top: 12),
    child: Row(
      children: [
        StatusDot(AgentStatus.working),
        SizedBox(width: 8),
        Text(
          'working…',
          style: TextStyle(
            fontFamily: monoFont,
            fontSize: 12,
            color: Graphite.working,
          ),
        ),
      ],
    ),
  );
}
