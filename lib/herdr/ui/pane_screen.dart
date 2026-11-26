import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../terminal/key_bar.dart';
import '../../ui/link_status.dart';
import '../../ui/palette.dart';
import '../api/herdr_client.dart';
import '../herdr_connection.dart';
import '../pane_poller.dart';
import '../pane_stream.dart';
import '../seen_marker.dart';
import '../server_api.dart';
import 'ansi_text.dart';
import 'herdr_lists.dart';
import 'link_chip.dart';

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
    this.draft,
    this.server = 'herdr',
    this.exactFirst = false,
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

  /// The text being typed, when the screen below keeps it while the pane
  /// is closed. A send that herdr took empties it.
  final TextEditingController? draft;

  /// The server's name in messages: herdr, or the Herdr app.
  final String server;

  /// Opens on the exact screen instead of the text view: where the server
  /// streams it, that view is live.
  final bool exactFirst;

  @override
  State<PaneScreen> createState() => _PaneScreenState();
}

class _PaneScreenState extends State<PaneScreen> {
  late final PanePoller _poller;
  late final PaneStream _stream;
  late final PaneSender _sender;
  late final AppLifecycleListener _lifecycle;
  late final Listenable _changes;
  late final _composer = widget.draft ?? TextEditingController();
  var _sending = false;

  /// The app is in front, and no other screen covers the pane.
  var _appShown = true;
  ValueListenable<TickerModeData>? _uncovered;
  var _shown = true;

  /// The poller reads: the pane is shown and the stream does not draw it.
  var _polling = true;

  /// Message and detail of the last input that failed.
  (String, String?)? _failure;

  late final SeenMarker _seen;

  @override
  void initState() {
    super.initState();
    PaneApi? api() => widget.connection.api;
    _poller = PanePoller(api, widget.paneId);
    _poller.source = _readSource;
    _sender = PaneSender(api, widget.paneId, onSent: _poller.kick);
    _lifecycle = AppLifecycleListener(
      onHide: () => _setAppShown(false),
      onShow: () => _setAppShown(true),
    );
    widget.onShown?.call(true);
    _seen = SeenMarker(widget.connection, widget.paneId, _poller);
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
    _changes = Listenable.merge([
      link,
      _poller.view,
      _stream.view,
      _stream.unavailable,
    ])..addListener(_applySource);
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

  /// Runs the stream or the poller, whichever shows the pane, and only
  /// while it is shown.
  void _applySource() {
    final streaming = _streaming;
    _stream.running = _shown && streaming;
    final polling = _shown && !streaming;
    if (polling == _polling) return;
    _polling = polling;
    polling ? _poller.resume() : _poller.pause();
  }

  @override
  void dispose() {
    _changes.removeListener(_applySource);
    _uncovered?.removeListener(_followShown);
    _lifecycle.dispose();
    _seen.dispose();
    widget.onShown?.call(false);
    _sender.cancel();
    _poller.dispose();
    _stream.dispose();
    if (widget.draft == null) _composer.dispose();
    super.dispose();
  }

  /// The exact screen, else the text view.
  late var _exact = widget.exactFirst;

  ReadSource get _readSource =>
      _exact ? ReadSource.visible : ReadSource.recentUnwrapped;

  void _toggleExact() => setState(() {
    _exact = !_exact;
    _poller.source = _readSource;
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
        setState(() => _failure = ('No link to ${widget.server}. Nothing was sent.', null));
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
      final view = _streaming ? _stream.view.value : _poller.view.value;
      final pane = snapshot?.pane(widget.paneId);
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
            IconButton(
              tooltip: _exact ? 'Text view' : 'Exact screen',
              icon: Icon(_exact ? Icons.notes : Icons.fit_screen_outlined),
              onPressed: _toggleExact,
            ),
            if (widget.showLink) ...linkActions(context, herdrLinkChip(state)),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              ?_statusBanner(state, view),
              Expanded(child: _content(state, view)),
              if (!view.gone) ...[
                if (pane?.status == AgentStatus.blocked)
                  _Answers(onKey: _sendKey),
                HerdrKeys(_paneKeys, onKey: _sendKey),
                _composerRow(pane),
              ],
            ],
          ),
        ),
      );
    },
  );

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
    if (state case LinkReconnecting() || LinkNoServer() || LinkFailed()) {
      return StatusBanner('No link to ${widget.server}. This text may be old.');
    }
    if (view.error case final error?) {
      return StatusBanner('Cannot read this pane.', detail: '$error');
    }
    return null;
  }

  Widget _content(LinkState state, PaneView view) {
    final text = view.text;
    if (text == null) {
      if (view.gone || view.error != null) return const SizedBox.shrink();
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
          label = 'Loading the pane…';
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
    return Opacity(
      opacity: state is LinkLive && !view.gone ? 1 : 0.5,
      child: _exact ? _ExactScreen(text) : _ReflowedText(text),
    );
  }

  Widget _composerRow(Pane? pane) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 2, 6, 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: _composer,
            minLines: 1,
            maxLines: 4,
            style: const TextStyle(fontFamily: monoFont, fontSize: 14),
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              hintText: pane?.agent == null
                  ? 'type to the shell…'
                  : 'prompt ${pane!.displayAgent ?? pane.agent}…',
            ),
          ),
        ),
        const SizedBox(width: 6),
        ListenableBuilder(
          listenable: _composer,
          builder: (context, _) => FilledButton(
            onPressed: _sending || _composer.text.trim().isEmpty
                ? null
                : () => unawaited(_submit(pane)),
            child: const Text('send'),
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
/// bottom. While the user reads further up, the text stays still.
class _ReflowedText extends StatefulWidget {
  const _ReflowedText(this.text);

  final String text;

  @override
  State<_ReflowedText> createState() => _ReflowedTextState();
}

class _ReflowedTextState extends State<_ReflowedText> {
  final _scroll = ScrollController();
  late String _shown;
  late List<TextSpan> _lines;

  void _show(String text) {
    _shown = text;
    _lines = parseAnsi(text);
    while (_lines.isNotEmpty && _lines.last.children!.isEmpty) {
      _lines.removeLast();
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
    itemCount: _lines.length,
    itemBuilder: (context, i) =>
        Text.rich(_lines[_lines.length - 1 - i], style: _paneStyle),
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
