import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../terminal/key_bar.dart';
import '../../ui/link_status.dart';
import '../../ui/palette.dart';
import '../api/herdr_client.dart';
import '../herdr_connection.dart';
import '../pane_poller.dart';
import '../seen_marker.dart';
import '../server_api.dart';
import 'ansi_text.dart';
import 'herdr_lists.dart';
import 'link_chip.dart';

const _paneStyle = TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.3);

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

  @override
  State<PaneScreen> createState() => _PaneScreenState();
}

class _PaneScreenState extends State<PaneScreen> {
  late final PanePoller _poller;
  late final PaneSender _sender;
  late final AppLifecycleListener _lifecycle;
  late final Listenable _changes;
  late final _composer = widget.draft ?? TextEditingController();
  var _sending = false;

  /// The app is in front, and no other screen covers the pane.
  var _appShown = true;
  ValueListenable<TickerModeData>? _uncovered;
  var _shown = true;

  /// Message and detail of the last input that failed.
  (String, String?)? _failure;

  late final SeenMarker _seen;

  @override
  void initState() {
    super.initState();
    PaneApi? api() => widget.connection.api;
    _poller = PanePoller(api, widget.paneId)..start();
    _sender = PaneSender(api, widget.paneId, onSent: _poller.kick);
    _lifecycle = AppLifecycleListener(
      onHide: () => _setAppShown(false),
      onShow: () => _setAppShown(true),
    );
    widget.onShown?.call(true);
    _seen = SeenMarker(widget.connection, widget.paneId, _poller);
    _changes = Listenable.merge([
      widget.connection.state,
      widget.connection.snapshot,
      _poller.view,
    ]);
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
    shown ? _poller.resume() : _poller.pause();
    widget.onShown?.call(shown);
    _seen.shown = shown;
  }

  @override
  void dispose() {
    _uncovered?.removeListener(_followShown);
    _lifecycle.dispose();
    _seen.dispose();
    widget.onShown?.call(false);
    _sender.cancel();
    _poller.dispose();
    if (widget.draft == null) _composer.dispose();
    super.dispose();
  }

  bool get _exact => _poller.source == ReadSource.visible;

  void _toggleExact() => setState(() {
    _poller.source = _exact ? ReadSource.recentUnwrapped : ReadSource.visible;
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
      final view = _poller.view.value;
      final pane = snapshot?.pane(widget.paneId);
      return Scaffold(
        backgroundColor: Mocha.base,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: switch (widget.onClose) {
            final close? => BackButton(onPressed: close),
            null => null,
          },
          title: _Header(paneId: widget.paneId, pane: pane, snapshot: snapshot),
          actions: [
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

  Widget? _statusBanner(LinkState state, PaneView view) {
    if (view.gone) return const StatusBanner('This pane is closed.');
    if (_failure case (final message, final detail)) {
      return StatusBanner(
        message,
        detail: detail,
        action: ('OK', () => setState(() => _failure = null)),
      );
    }
    if (state is! LinkLive) {
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
      return view.gone || view.error != null
          ? const SizedBox.shrink()
          : const Center(child: CircularProgressIndicator());
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
            style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
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
                style: const TextStyle(fontFamily: 'monospace', fontSize: 16),
              ),
            ),
          ],
        ),
        Text(
          place,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 11,
            color: Mocha.overlay,
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
            fontFamily: 'monospace',
            fontSize: 12,
            color: Mocha.red,
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
class _ExactScreen extends StatelessWidget {
  const _ExactScreen(this.text);

  final String text;

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
          for (final line in parseAnsi(text))
            Text.rich(line, style: _paneStyle, softWrap: false),
        ],
      ),
    ),
  );
}
