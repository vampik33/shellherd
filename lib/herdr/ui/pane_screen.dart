import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../terminal/key_bar.dart';
import '../../ui/link_status.dart';
import '../../ui/palette.dart';
import '../api/herdr_client.dart';
import '../herdr_connection.dart';
import '../pane_history.dart';
import '../pane_poller.dart';
import '../pane_stream.dart';
import '../seen_marker.dart';
import '../server_api.dart';
import '../transcript/claude_sessions.dart';
import '../transcript/slash_commands.dart';
import '../transcript/transcript_stream.dart';
import 'ansi_text.dart';
import 'chat_details.dart';
import 'chat_view.dart';
import 'herdr_lists.dart';
import 'link_chip.dart';
import 'slash_menu.dart';

const _paneStyle = TextStyle(fontFamily: monoFont, fontSize: 13, height: 1.3);

const _paneKeys = [
  ('esc', 'esc'),
  ('ctrl+c', 'ctrl+c'),
  ('tab', 'tab'),
  ('shift+tab', 'shift+tab'),
  ('↑', 'up'),
  ('↓', 'down'),
  ('←', 'left'),
  ('→', 'right'),
  ('enter', 'enter'),
];

/// The answers to the numbered question of a blocked agent.
const _answerKeys = [('1', '1'), ('2', '2'), ('3', '3'), ('esc', 'esc')];

/// One pane of the herdr session: its text, and input to it.
class PaneScreen extends StatefulWidget {
  const PaneScreen({
    super.key,
    required this.connection,
    required this.paneId,
    this.onShown,
    this.onClose,
    this.showLink = true,
    this.onDisconnect,
    this.draft,
    this.server = 'herdr',
    this.exactFirst = false,
    this.chatDetails,
  });

  /// Owned by the screen below this one.
  final HerdrConnection connection;
  final String paneId;

  /// True while the pane is on the screen, false when the app hides, a
  /// screen covers it or it goes.
  final void Function(bool shown)? onShown;

  /// The back arrow. The pane is no route of its own: it stands in the
  /// herdr screen.
  final VoidCallback? onClose;

  /// The chip of the link and the Disconnect button; off where the herdr
  /// screen shows them already.
  final bool showLink;

  /// The user pressed Disconnect; the screen goes back to the host list.
  final VoidCallback? onDisconnect;

  /// The text being typed, when the screen below keeps it while the pane
  /// is closed. A send that herdr took empties it.
  final TextEditingController? draft;

  /// The server's name in messages: herdr, or the Herdr app.
  final String server;

  /// Opens a pane without a Claude Code session on the exact screen
  /// instead of the text view: where the server streams it, that view is
  /// live. The pane of a session opens on its chat.
  final bool exactFirst;

  /// Whether the chat shows thinking and tool calls; the app's saved
  /// choice. Without it, the screen keeps its own, hidden at first.
  final ChatDetails? chatDetails;

  @override
  State<PaneScreen> createState() => _PaneScreenState();
}

class _PaneScreenState extends State<PaneScreen> {
  late final PanePoller _poller;
  late final PaneStream _stream;
  late final TranscriptStream _transcript;
  late final PaneSender _sender;
  late final AppLifecycleListener _lifecycle;
  late final Listenable _changes;
  late final _composer = widget.draft ?? TextEditingController();
  final _composerFocus = FocusNode();
  var _sending = false;

  /// Claude Code's slash commands on the host, for the menu.
  final _slash = SlashCommands();

  /// The app is in front, and no other screen covers the pane.
  var _appShown = true;
  ValueListenable<TickerModeData>? _uncovered;
  var _shown = true;

  /// The poller reads: the pane is shown and the stream does not draw it.
  var _polling = true;

  /// Message and detail of the last input that failed.
  (String, String?)? _failure;

  late final SeenMarker _seen;

  /// The chat is on the screen and current, for [_seen].
  final _chatCurrent = ValueNotifier(false);

  late final _details = widget.chatDetails ?? ChatDetails();

  @override
  void initState() {
    super.initState();
    PaneApi? api() => widget.connection.api;
    _poller = PanePoller(api, widget.paneId);
    _sender = PaneSender(api, widget.paneId, onSent: _poller.kick);
    _lifecycle = AppLifecycleListener(
      onHide: () => _setAppShown(false),
      onShow: () => _setAppShown(true),
    );
    widget.onShown?.call(true);
    _seen = SeenMarker(
      widget.connection,
      widget.paneId,
      _poller,
      current: _chatCurrent,
    );
    final link = Listenable.merge([
      widget.connection.state,
      widget.connection.snapshot,
    ]);
    _stream = PaneStream(
      () => widget.connection.screens,
      widget.paneId,
      _paneSize,
      changes: link,
    );
    _transcript = TranscriptStream(
      () => widget.connection.transcripts,
      () => _claudeSession,
      changes: link,
      ranges: () => widget.connection.transcriptRanges,
    );
    _changes = Listenable.merge([
      link,
      _poller.view,
      _stream.view,
      _stream.unavailable,
      _transcript.view,
      _transcript.unavailable,
      _transcript.live,
      _details,
    ])..addListener(_applySource);
    widget.connection.state.addListener(_clearNoLinkFailure);
    _changes.addListener(_wantSlashCommands);
    _composer.addListener(_wantSlashCommands);
    // A read that ends can be for a directory the pane has left.
    _slash.addListener(_wantSlashCommands);
    // A draft can start with a slash.
    _wantSlashCommands();
    // Before the first read: with a stream, the poller does not read.
    _applySource();
    _poller.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A screen pushed on top, such as the terminal from a wide herdr
    // screen, turns the tickers of this one off.
    final uncovered = TickerMode.getValuesNotifier(context);
    if (uncovered == _uncovered) return;
    _uncovered?.removeListener(_followShown);
    _uncovered = uncovered..addListener(_followShown);
    _followShown();
  }

  void _setAppShown(bool shown) {
    _appShown = shown;
    _followShown();
  }

  /// Polls and tells [PaneScreen.onShown] only while the pane can be seen.
  void _followShown() {
    final shown = _appShown && (_uncovered?.value.enabled ?? true);
    if (shown == _shown) return;
    _shown = shown;
    _applySource();
    widget.onShown?.call(shown);
    _seen.shown = shown;
  }

  /// The exact screen comes from the stream while an observer can run. It
  /// keeps its last text only while the link is down; a live link that
  /// cannot observe, for example without the pane size, reads the pane.
  bool get _streaming =>
      _exact &&
      (_stream.canObserve ||
          (!_stream.unavailable.value &&
              widget.connection.state.value is! LinkLive &&
              _stream.view.value.text != null));

  PaneSize? _paneSize() =>
      widget.connection.snapshot.value?.paneSizes[widget.paneId];

  Pane? get _pane => widget.connection.snapshot.value?.pane(widget.paneId);

  /// The Claude Code session of the pane, whose transcript the chat shows.
  String? get _claudeSession => _pane?.agentSession?.claudeSession;

  /// Claude Code runs in the pane: the composer offers its slash commands.
  bool get _claudeCode {
    final agent = _pane?.agent;
    return _claudeSession != null ||
        agent == 'claude' ||
        agent == claudeCodeApp;
  }

  /// Reads the host's slash commands while the menu shows, when they are
  /// not current. A terminal of another machine the Herdr app connects to
  /// (`machine/t7`) has its commands there: it gets only the built-ins.
  void _wantSlashCommands() {
    if (!_claudeCode || slashQuery(_composer.text) == null) return;
    if (widget.paneId.contains('/')) return;
    _slash.want(widget.connection.slashCommands, _pane?.cwd);
  }

  /// Puts [command] in the composer, ready for its arguments.
  void _pickSlashCommand(SlashCommand command) =>
      _setComposer('/${command.name} ');

  /// Puts [text] in the composer with the cursor after it. Not
  /// `_composer.text`, which drops the cursor: a field that has focus
  /// already would type before the text.
  void _setComposer(String text) {
    _composer.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _composerFocus.requestFocus();
  }

  /// The pane has a transcript the chat can show: one of a Claude Code
  /// session that the snapshot names, whose read did not fail.
  bool get _chatAvailable =>
      _claudeSession != null && !_transcript.unavailable.value;

  /// The chat shows in place of the text view while a read can run. It
  /// keeps its messages only while the link is down.
  bool get _chatting =>
      !_exact &&
      _chatAvailable &&
      (_transcript.canRead ||
          (widget.connection.state.value is! LinkLive &&
              _transcript.view.value.items != null));

  /// The chat is on the screen: it runs and has a message, or loads. Until
  /// the first message, for example before Claude Code wrote its
  /// transcript, the pane shows its text; so it does while the agent is
  /// blocked, as only the pane shows the question it asks.
  bool get _chatShown {
    if (!_chatting || _pane?.status == AgentStatus.blocked) return false;
    final view = _transcript.view.value;
    final items = view.items;
    return items == null || items.isNotEmpty || view.startsCut;
  }

  /// What shows the pane now. The banner and the content read only its
  /// view.
  _Feed get _feed => _streaming
      ? _Feed.stream
      : _chatShown
      ? _Feed.chat
      : _Feed.reads;

  /// Runs the stream, the transcript read or the poller, whichever shows
  /// the pane, and only while it is shown. The poller rests while the chat
  /// shows: a current chat is what [SeenMarker] waits for then.
  void _applySource() {
    if (_poller.source != _readSource) _poller.source = _readSource;
    final feed = _feed;
    _stream.running = _shown && feed == _Feed.stream;
    _transcript.running = _shown && _chatting;
    _chatCurrent.value = feed == _Feed.chat && _transcript.live.value;
    final polling = _shown && feed == _Feed.reads;
    if (polling == _polling) return;
    _polling = polling;
    polling ? _poller.resume() : _poller.pause();
  }

  /// Once the link is up, "Nothing was sent" for want of it is old news.
  void _clearNoLinkFailure() {
    if (widget.connection.state.value is LinkLive &&
        _failure?.$1 == _noLinkFailure) {
      setState(() => _failure = null);
    }
  }

  String get _noLinkFailure => 'No link to ${widget.server}. Nothing was sent.';

  @override
  void dispose() {
    _changes.removeListener(_applySource);
    _changes.removeListener(_wantSlashCommands);
    _composer.removeListener(_wantSlashCommands);
    _slash.removeListener(_wantSlashCommands);
    _slash.dispose();
    _composerFocus.dispose();
    widget.connection.state.removeListener(_clearNoLinkFailure);
    _uncovered?.removeListener(_followShown);
    _lifecycle.dispose();
    _seen.dispose();
    _chatCurrent.dispose();
    if (widget.chatDetails == null) _details.dispose();
    widget.onShown?.call(false);
    _sender.cancel();
    _poller.dispose();
    _stream.dispose();
    _transcript.dispose();
    if (widget.draft == null) _composer.dispose();
    super.dispose();
  }

  /// The user's own choice of the exact screen or not; null until they
  /// toggle.
  bool? _exactChosen;

  /// The exact screen, else the chat or the text view: the user's choice,
  /// else the exact screen when [PaneScreen.exactFirst] and the pane has no
  /// Claude Code session. The snapshot can name the session only after the
  /// pane opened, for example from a notification.
  bool get _exact =>
      _exactChosen ?? (widget.exactFirst && _claudeSession == null);

  ReadSource get _readSource =>
      _exact ? ReadSource.visible : ReadSource.recentUnwrapped;

  void _toggleExact() => setState(() {
    _exactChosen = !_exact;
    _applySource();
  });

  /// Runs [send] and reports its failure. True if it worked.
  Future<bool> _guarded(Future<void> Function() send) async {
    try {
      await send();
      if (mounted) setState(() => _failure = null);
      return true;
    } on PaneInputNotSent catch (e) {
      if (e.noLink && mounted) {
        setState(() => _failure = (_noLinkFailure, null));
      }
    } on HerdrException catch (e) {
      if (mounted) setState(() => _failure = _sendFailure(e));
    }
    return false;
  }

  (String, String?) _sendFailure(HerdrException e) => switch (e) {
    HerdrApiException(code: 'agent_blocked') => (
      'The agent is waiting for an answer. Your text was not sent.',
      null,
    ),
    // herdr knows of an agent here, but it does not run in front now, for
    // example after it quit to the shell.
    HerdrApiException(code: 'agent_not_ready') => (
      'The agent is not running in this pane now. Your text was not sent.',
      null,
    ),
    HerdrTimeoutException() || HerdrConnectionClosedException() => (
      'No answer from ${widget.server}. The input may have arrived anyway.',
      '$e',
    ),
    _ => ('${widget.server} did not take the input.', '$e'),
  };

  void _sendKey(String key) => unawaited(_guarded(() => _sender.keys([key])));

  Future<void> _submit(Pane? pane) async {
    final text = _composer.text;
    if (_sending || text.trim().isEmpty) return;
    setState(() => _sending = true);
    try {
      final sent = await _guarded(
        () => _sender.prompt(text, toAgent: pane?.agent != null),
      );
      // The user may have typed on while it was on its way.
      if (mounted && sent && _composer.text == text) _composer.clear();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _changes,
    builder: (context, _) {
      final snapshot = widget.connection.snapshot.value;
      final state = widget.connection.state.value;
      final feed = _feed;
      // The chat has no pane text: the poller rests under it, and what it
      // read last is old. A read still on its way when the chat came can
      // find the pane closed: that shows, its errors do not.
      final view = switch (feed) {
        _Feed.stream => _stream.view.value,
        _Feed.chat => PaneView(gone: _poller.view.value.gone),
        _Feed.reads => _poller.view.value,
      };
      final pane = snapshot?.pane(widget.paneId);
      // Where the toggle goes.
      final toggle = !_exact
          ? ('Exact screen', Icons.fit_screen_outlined)
          : _chatAvailable
          ? ('Chat', Icons.chat_bubble_outline)
          : ('Text view', Icons.notes);
      return Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: switch (widget.onClose) {
            final close? => BackButton(onPressed: close),
            null => null,
          },
          title: _Header(paneId: widget.paneId, pane: pane, snapshot: snapshot),
          actions: [
            if (_exact) _feedIcon(state),
            if (feed == _Feed.chat) _detailsToggle(),
            IconButton(
              tooltip: toggle.$1,
              icon: Icon(toggle.$2),
              onPressed: _toggleExact,
            ),
            if (widget.showLink)
              ...linkActions(
                context,
                herdrLinkChip(state),
                onDisconnect: widget.onDisconnect,
              ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              ?_statusBanner(state, view),
              Expanded(child: _content(state, feed, view)),
              if (!view.gone) ...[
                if (pane?.status == AgentStatus.blocked)
                  _Answers(onKey: _sendKey),
                HerdrKeys(_paneKeys, onKey: _sendKey),
                if (_claudeCode) _slashMenu(),
                _composerRow(pane),
              ],
            ],
          ),
        ),
      );
    },
  );

  /// Shows or hides the agent's thinking and tool calls in the chat.
  Widget _detailsToggle() {
    final shown = _details.value;
    return IconButton(
      tooltip: shown
          ? 'Hide thinking and tool calls'
          : 'Show thinking and tool calls',
      isSelected: shown,
      icon: const Icon(Icons.psychology_outlined),
      selectedIcon: const Icon(Icons.psychology, color: Graphite.accent),
      onPressed: () => unawaited(_details.choose(!shown)),
    );
  }

  /// How the exact screen gets here: pushed live, or read again and again.
  /// A tap says why.
  Widget _feedIcon(LinkState state) {
    final live = _streaming;
    final why = _stream.whyUnavailable;
    final message = live
        ? 'Live: ${widget.server} sends each change of the screen as it '
              'happens.'
        : _stream.unavailable.value
        ? 'Read again every few seconds: the live screen did not start'
              '${why == null ? '' : ' ($why)'}. It is tried again after the '
              'next reconnect.'
        : state is LinkLive
        ? 'Read again every few seconds: ${widget.server} sends no live '
              'screen.'
        : 'No link to ${widget.server} yet.';
    return IconButton(
      tooltip: live ? 'Live screen' : 'Screen read again',
      icon: Icon(
        live ? Icons.bolt : Icons.sync,
        color: live ? Graphite.green : Graphite.dim,
      ),
      onPressed: () => ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(message))),
    );
  }

  Widget? _statusBanner(LinkState state, PaneView view) {
    if (view.gone) return const StatusBanner('This pane is closed.');
    if (_failure case (final message, final detail)) {
      return StatusBanner(
        message,
        detail: detail,
        action: ('OK', () => setState(() => _failure = null)),
      );
    }
    // The first connect is no failure: the content says it is loading.
    final lost = switch (state) {
      LinkReconnecting() || LinkNoServer() || LinkFailed() => true,
      LinkOffline() || LinkConnecting() || LinkSyncing() || LinkLive() => false,
    };
    if (lost) {
      return StatusBanner('No link to ${widget.server}. This text may be old.');
    }
    if (view.error case final error?) {
      return StatusBanner('Cannot read this pane.', detail: '$error');
    }
    if (!_exact && _claudeSession != null && _transcript.unavailable.value) {
      return StatusBanner(
        'Cannot read the conversation. This is the pane\'s text.',
        detail: _transcript.whyUnavailable,
      );
    }
    return null;
  }

  Widget _chat(LinkState state) {
    final transcript = _transcript.view.value;
    final items = transcript.items;
    if (items == null) return _loading(state, 'Loading the conversation…');
    return Opacity(
      opacity: state is LinkLive ? 1 : 0.5,
      child: ChatView(
        items: items,
        startsCut: transcript.startsCut,
        firstKey: transcript.firstKey,
        earlier: transcript.earlier,
        onLoadEarlier: widget.connection.transcriptRanges == null
            ? null
            : () => unawaited(_transcript.loadEarlier()),
        status: _pane?.status,
        showDetails: _details.value,
      ),
    );
  }

  Widget _content(LinkState state, _Feed feed, PaneView view) {
    if (feed == _Feed.chat) return _chat(state);
    final text = view.text;
    if (text == null) {
      if (view.gone || view.error != null) return const SizedBox.shrink();
      return _loading(state, 'Loading the pane…');
    }
    return Opacity(
      opacity: state is LinkLive && !view.gone ? 1 : 0.5,
      child: _exact
          ? _ExactScreen(text)
          : _ReflowedText(text, readHistory: _readHistory),
    );
  }

  /// The pane's text with up to [lines] lines, for the text view's older
  /// lines.
  Future<String> _readHistory(int lines) async {
    final api = widget.connection.api;
    if (api == null) throw StateError('no link to ${widget.server}');
    return api.read(
      widget.paneId,
      source: ReadSource.recentUnwrapped,
      lines: lines,
    );
  }

  /// A spinner while the content first loads, with [loading] once the
  /// link is up.
  Widget _loading(LinkState state, String loading) {
    final String? label;
    switch (state) {
      // Nothing retries: the banner says what is wrong.
      case LinkNoServer() || LinkFailed():
        return const SizedBox.shrink();
      // The banner says the link is lost.
      case LinkReconnecting():
        label = null;
      case LinkOffline() || LinkConnecting():
        label = 'Connecting to ${widget.server}…';
      case LinkSyncing() || LinkLive():
        label = loading;
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (label != null) ...[
            const SizedBox(height: 12),
            Text(label, style: const TextStyle(color: Graphite.dim)),
          ],
        ],
      ),
    );
  }

  /// The commands that match what is typed, while it is a slash command's
  /// name.
  Widget _slashMenu() => ListenableBuilder(
    listenable: Listenable.merge([_composer, _slash]),
    builder: (context, _) {
      final query = slashQuery(_composer.text);
      if (query == null) return const SizedBox.shrink();
      final commands = slashMatches(
        query,
        _slash.found,
        recent: recentSlashCommands(_transcript.view.value.items ?? const []),
      );
      final note = _slash.loading
          ? 'Reading the commands on the host…'
          : _slash.failed
          ? 'Cannot read the commands on the host.'
          : null;
      if (commands.isEmpty && note == null) return const SizedBox.shrink();
      return SlashMenu(
        commands: commands,
        onPick: _pickSlashCommand,
        note: note,
      );
    },
  );

  Widget _composerRow(Pane? pane) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 2, 6, 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (_claudeCode)
          ListenableBuilder(
            listenable: _composer,
            builder: (context, _) => IconButton(
              tooltip: 'Commands',
              onPressed: _composer.text.isEmpty
                  ? () => _setComposer('/')
                  : null,
              icon: const Text(
                '/',
                style: TextStyle(fontFamily: monoFont, fontSize: 20),
              ),
            ),
          ),
        Expanded(
          child: TextField(
            controller: _composer,
            focusNode: _composerFocus,
            minLines: 1,
            maxLines: 4,
            style: const TextStyle(fontFamily: monoFont, fontSize: 14),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: Graphite.raised,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 14,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
              hintText: pane?.agent == null
                  ? 'type to the shell…'
                  : 'prompt ${pane!.displayAgent ?? pane.agent}…',
            ),
          ),
        ),
        const SizedBox(width: 6),
        ListenableBuilder(
          listenable: _composer,
          builder: (context, _) => IconButton.filled(
            tooltip: 'Send',
            onPressed: _sending || _composer.text.trim().isEmpty
                ? null
                : () => unawaited(_submit(pane)),
            icon: const Icon(Icons.arrow_upward),
          ),
        ),
      ],
    ),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.paneId, this.pane, this.snapshot});

  final String paneId;
  final Pane? pane;
  final HerdrSnapshot? snapshot;

  @override
  Widget build(BuildContext context) {
    final pane = this.pane;
    final place = [
      if (pane != null) ...[
        ?snapshot?.workspace(pane.workspaceId)?.label,
        ?snapshot?.tab(pane.tabId)?.label,
      ],
      paneId,
    ].join(' › ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (pane != null) ...[
              StatusDot(pane.status),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                pane?.displayName ?? paneId,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontFamily: monoFont, fontSize: 16),
              ),
            ),
          ],
        ),
        Text(
          place,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: monoFont,
            fontSize: 11,
            color: Graphite.dim,
          ),
        ),
      ],
    );
  }
}

/// The quick answers. The question itself stands in the pane text.
class _Answers extends StatelessWidget {
  const _Answers({required this.onKey});

  final void Function(String key) onKey;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 12, top: 4),
    child: Row(
      children: [
        const StatusDot(AgentStatus.blocked),
        const SizedBox(width: 8),
        const Text(
          'needs you',
          style: TextStyle(
            fontFamily: monoFont,
            fontSize: 12,
            color: Graphite.blocked,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: HerdrKeys(_answerKeys, onKey: onKey)),
      ],
    ),
  );
}

/// Whole lines that wrap at the width of the phone, the newest at the
/// bottom. While the user reads further up, the text stays still; at the
/// top of a text of [PanePoller.historyLines] lines, older lines load
/// above, the steps of [historySteps] at a time.
class _ReflowedText extends StatefulWidget {
  const _ReflowedText(this.text, {required this.readHistory});

  final String text;

  /// Reads the pane's text with up to the given number of lines.
  final Future<String> Function(int lines) readHistory;

  @override
  State<_ReflowedText> createState() => _ReflowedTextState();
}

class _ReflowedTextState extends State<_ReflowedText> {
  final _scroll = ScrollController();
  late String _shown;
  late List<TextSpan> _lines;

  /// How many lines the read of [_shown] asked for.
  var _depth = PanePoller.historyLines;

  /// The pane may have lines older than [_shown].
  var _older = false;
  var _earlier = EarlierLoad.idle;

  /// Bumped when [_shown] changes: a load for an older one is dropped.
  var _version = 0;

  /// Shows [text], read with up to [depth] lines; [older] when it may
  /// not hold the oldest. A text with fewer lines than it asked for holds
  /// them all.
  void _show(String text, {int depth = PanePoller.historyLines, bool? older}) {
    _shown = text;
    _depth = depth;
    _older = older ?? '\n'.allMatches(text).length + 1 >= depth;
    _earlier = EarlierLoad.idle;
    _version++;
    _lines = parseAnsi(text);
    while (_lines.isNotEmpty && _lines.last.children!.isEmpty) {
      _lines.removeLast();
    }
  }

  /// Reads the next step of [historySteps] and puts the lines older than
  /// [_shown] above it, which stays as it is; or the whole read, where it
  /// does not hold the start of [_shown].
  Future<void> _loadOlder() async {
    if (!_older || _earlier == EarlierLoad.loading) return;
    final depth = historySteps.where((d) => d > _depth).firstOrNull;
    if (depth == null) {
      setState(() => _earlier = EarlierLoad.capped);
      return;
    }
    final version = _version;
    final shown = _shown;
    setState(() => _earlier = EarlierLoad.loading);
    try {
      final read = await widget.readHistory(depth);
      if (!mounted || version != _version) return;
      final shownLines = shown.split('\n');
      final readLines = read.split('\n');
      final older = olderLines(shownLines, readLines);
      final text = older == null
          ? read
          : [...readLines.take(older), ...shownLines].join('\n');
      setState(() {
        _show(
          text,
          depth: depth,
          older: older != 0 && readLines.length >= depth,
        );
        if (_older && depth == historySteps.last) {
          _earlier = EarlierLoad.capped;
        }
      });
    } catch (e) {
      if (!mounted || version != _version) return;
      debugPrint('shellherd: cannot load older lines of the pane: $e');
      setState(() => _earlier = EarlierLoad.failed);
    }
  }

  bool get _scrolledUp => _scroll.hasClients && _scroll.offset > 1;

  @override
  void initState() {
    super.initState();
    _show(widget.text);
    _scroll.addListener(_release);
  }

  @override
  void didUpdateWidget(_ReflowedText old) {
    super.didUpdateWidget(old);
    if (widget.text != old.text && !_scrolledUp) _show(widget.text);
  }

  void _release() {
    if (_shown == widget.text || _scrolledUp) return;
    setState(() => _show(widget.text));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView.builder(
    controller: _scroll,
    reverse: true,
    padding: const EdgeInsets.all(6),
    itemCount: _lines.length + (_older ? 1 : 0),
    itemBuilder: (context, i) => i == _lines.length
        ? EarlierRow(
            _earlier,
            () => unawaited(_loadOlder()),
            what: 'older lines',
          )
        : Text.rich(_lines[_lines.length - 1 - i], style: _paneStyle),
  );
}

/// The pane exactly as herdr draws it, scaled to fit. Pinch to zoom.
class _ExactScreen extends StatefulWidget {
  const _ExactScreen(this.text);

  final String text;

  @override
  State<_ExactScreen> createState() => _ExactScreenState();
}

/// Parses the text only when it changes: the screen also rebuilds for the
/// link and the snapshot, and a stream draws often.
class _ExactScreenState extends State<_ExactScreen> {
  late var _lines = parseAnsi(widget.text);

  @override
  void didUpdateWidget(_ExactScreen old) {
    super.didUpdateWidget(old);
    if (widget.text != old.text) _lines = parseAnsi(widget.text);
  }

  @override
  Widget build(BuildContext context) => InteractiveViewer(
    maxScale: 8,
    child: FittedBox(
      fit: BoxFit.contain,
      alignment: Alignment.topLeft,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in _lines)
            Text.rich(line, style: _paneStyle, softWrap: false),
        ],
      ),
    ),
  );
}

/// What shows a pane.
enum _Feed {
  /// The exact screen, pushed by the stream.
  stream,

  /// The conversation, from the transcript.
  chat,

  /// The pane's text, read again and again by the poller.
  reads,
}
