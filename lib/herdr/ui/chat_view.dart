import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../ui/palette.dart';
import '../api/herdr_client.dart';
import '../transcript/chat_items.dart';
import '../transcript/transcript_stream.dart';
import 'herdr_lists.dart';

const _monoStyle = TextStyle(fontFamily: monoFont, fontSize: 12, height: 1.35);

/// An agent's conversation as a chat: the user's prompts in bubbles on the
/// right, the agent's replies in markdown on the left, its tool calls as
/// rows that open on a tap. The newest is at the bottom. While the user
/// reads further up, the chat stays still, but earlier messages that load
/// show above. Without [showDetails], thinking and tool calls are left out.
class ChatView extends StatefulWidget {
  const ChatView({
    super.key,
    required this.items,
    this.startsCut = false,
    this.firstKey = 0,
    this.earlier = EarlierLoad.idle,
    this.onLoadEarlier,
    this.status,
    this.showDetails = true,
  });

  final List<ChatItem> items;

  /// Older messages were not read: the top says so, or loads them.
  final bool startsCut;

  /// See [TranscriptView.firstKey].
  final int firstKey;

  /// How loading the older messages goes.
  final EarlierLoad earlier;

  /// Loads the older messages; called when the top of the chat comes near
  /// while [earlier] is idle. Without it, the top only says that they are
  /// not shown.
  final VoidCallback? onLoadEarlier;

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

  /// The [ChatView.firstKey] of [_shown].
  late int _shownFirst;

  bool get _scrolledUp => _scroll.hasClients && _scroll.offset > 1;

  @override
  void initState() {
    super.initState();
    _shown = widget.items;
    _shownFirst = widget.firstKey;
    _scroll.addListener(_release);
  }

  @override
  void didUpdateWidget(ChatView old) {
    super.didUpdateWidget(old);
    if (!_scrolledUp) {
      _shown = widget.items;
      _shownFirst = widget.firstKey;
    } else {
      // Earlier messages go above what shows: the reverse list keeps the
      // place of what is below.
      final front = min(_shownFirst - widget.firstKey, widget.items.length);
      if (front > 0) {
        final rest = widget.items.skip(front).take(_shown.length).toList();
        // Earlier lines can drop a later copy of a record they hold; then
        // what shows is the new items, as many as before.
        _shown = listEquals(rest, _shown)
            ? [...widget.items.take(front), ..._shown]
            : widget.items.take(front + _shown.length).toList();
        _shownFirst -= front;
      }
      // A shorter list can end the scroll without telling the listener:
      // check again once it is laid out.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _release();
      });
    }
  }

  void _release() {
    if (identical(_shown, widget.items) || _scrolledUp) return;
    setState(() {
      _shown = widget.items;
      _shownFirst = widget.firstKey;
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Without details, thinking and tool calls are left out. Where each
    // item shown stands in [_shown], for its key.
    final places = [
      for (var i = 0; i < _shown.length; i++)
        if (widget.showDetails ||
            (_shown[i] is! ChatThinking && _shown[i] is! ChatTool))
          i,
    ];
    final items = [for (final i in places) _shown[i]];
    final working = widget.status == AgentStatus.working;
    if (items.isEmpty && !widget.startsCut && !working) {
      return const Center(
        child: Text('No messages yet.', style: TextStyle(color: Graphite.dim)),
      );
    }
    // The list runs from the bottom: index 0 is the working line, when
    // there is one, then the newest item. Items keep the key of their
    // number ([ChatView.firstKey] for the first), so that a row stays open
    // as new ones come and earlier ones load; tool calls the key of their
    // id, so that one stays open when a new read starts at another record.
    final lead = working ? 1 : 0;
    final count = lead + items.length + (widget.startsCut ? 1 : 0);
    Key key(int at) => _key(_shown, places[at], _shownFirst);
    // Built on the first lookup only.
    Map<Key, int>? keyAt;
    final markdown = _markdownStyle(Theme.of(context));
    return ListView.builder(
      controller: _scroll,
      reverse: true,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      itemCount: count,
      findChildIndexCallback: (wanted) {
        final at = (keyAt ??= {
          for (var at = 0; at < items.length; at++) key(at): at,
        })[wanted];
        return at == null ? null : lead + items.length - 1 - at;
      },
      itemBuilder: (context, i) {
        if (i < lead) return const _Working();
        final at = items.length - 1 - (i - lead);
        if (at < 0) return EarlierRow(widget.earlier, widget.onLoadEarlier);
        return KeyedSubtree(
          key: key(at),
          child: _row(
            items[at],
            previous: at > 0 ? items[at - 1] : null,
            markdown: markdown,
          ),
        );
      },
    );
  }

  static Key _key(List<ChatItem> items, int at, int first) =>
      switch (items[at]) {
        ChatTool(:final id) => ValueKey(('tool', id)),
        _ => ValueKey(first + at),
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

/// The top of a list that starts after the start of what it shows, such
/// as a chat cut at the start of its transcript: it loads [what] once it is
/// built, near the top of the screen, or says why it does not.
class EarlierRow extends StatelessWidget {
  const EarlierRow(
    this.state,
    this.onLoad, {
    super.key,
    this.what = 'earlier messages',
  });

  final EarlierLoad state;

  /// Null where nothing can load them.
  final VoidCallback? onLoad;

  /// What loads, in lower case, such as "earlier messages".
  final String what;

  @override
  Widget build(BuildContext context) {
    final load = onLoad;
    final capital = '${what[0].toUpperCase()}${what.substring(1)}';
    if (load == null) return _Note('$capital are not shown.');
    switch (state) {
      case EarlierLoad.idle:
        // Not during the build: the load changes what the list shows.
        WidgetsBinding.instance.addPostFrameCallback((_) => load());
        return _Loading(what);
      case EarlierLoad.loading:
        return _Loading(what);
      case EarlierLoad.failed:
        return InkWell(
          onTap: load,
          child: _Note('Cannot load $what. Tap to try again.'),
        );
      case EarlierLoad.capped:
        return _Note('$capital are not loaded.');
      case EarlierLoad.none:
        return _Note('$capital are not shown.');
    }
  }
}

class _Loading extends StatelessWidget {
  const _Loading(this.what);

  final String what;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox.square(
          dimension: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 8),
        Text(
          'Loading $what…',
          style: const TextStyle(fontSize: 12, color: Graphite.dim),
        ),
      ],
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
