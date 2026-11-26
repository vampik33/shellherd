import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../ssh/host.dart';
import '../../ssh/ssh_connector.dart';
import '../../ui/link_status.dart';
import '../../ui/palette.dart';
import '../api/herdr_client.dart';
import '../herdr_connection.dart';
import 'chat_details.dart';
import 'herdr_lists.dart';
import 'link_chip.dart';
import 'pane_screen.dart';

/// From this width on, the herdr screen shows the sidebar and the pane side
/// by side.
const wideLayoutWidth = 840.0;

/// The herdr session of one PC: phone lists, or on a wide screen the
/// sidebar and the open pane side by side.
class HerdrScreen extends StatefulWidget {
  const HerdrScreen({
    super.key,
    required this.host,
    required this.createConnection,
    required this.onTerminal,
    this.openPane,
    this.onPaneShown,
    this.onDisconnect,
    this.chatDetails,
  });

  final Host host;

  /// Called once. A route can build this widget again, for example when the
  /// screen turns, and that must not start a second connection.
  final HerdrConnection Function() createConnection;

  /// Opens a plain terminal on the PC.
  final VoidCallback onTerminal;

  /// A pane to open at once, for a tapped notification.
  final String? openPane;

  /// Gets each pane that comes on the screen or goes from it.
  final void Function(String paneId, bool shown)? onPaneShown;

  /// The user pressed Disconnect; the screen goes back to the host list.
  final VoidCallback? onDisconnect;

  /// See [PaneScreen.chatDetails].
  final ChatDetails? chatDetails;

  @override
  State<HerdrScreen> createState() => _HerdrScreenState();
}

class _HerdrScreenState extends State<HerdrScreen> {
  /// The last item of the bar is no tab: it opens the terminal on top.
  static const _terminalDestination = 2;

  late final HerdrConnection _link;
  var _tab = 0;

  /// The open pane, in either layout.
  String? _pane;

  /// Keeps the pane screen, its text and what the user typed, when the
  /// layout changes. A new one for each pane.
  var _paneKey = GlobalKey();

  /// What the user typed in each pane, kept while another one is open.
  final _drafts = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _link = widget.createConnection()..connect();
    _pane = widget.openPane;
  }

  @override
  void dispose() {
    for (final draft in _drafts.values) {
      draft.dispose();
    }
    _link.dispose();
    super.dispose();
  }

  String get _title => switch (widget.host.herdrSession) {
    final session? => '${widget.host.label} · $session',
    null => widget.host.label,
  };

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= wideLayoutWidth;
    final pane = _pane;
    return PopScope(
      // On a phone, back closes the open pane first.
      canPop: wide || pane == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closePane();
      },
      child: switch ((wide, pane)) {
        (false, final pane?) => _paneScreen(pane, wide: false),
        _ => ValueListenableBuilder(
          valueListenable: _link.state,
          builder: (context, state, _) => _scaffold(state, wide: wide),
        ),
      },
    );
  }

  /// The phone and the wide layout differ only in the body and in where
  /// the terminal opens.
  Widget _scaffold(LinkState state, {required bool wide}) => Scaffold(
    appBar: AppBar(
      title: Text(_title),
      actions: [
        if (wide)
          IconButton(
            tooltip: 'terminal',
            icon: const Icon(Icons.terminal),
            onPressed: widget.onTerminal,
          ),
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
          ?_banner(state),
          Expanded(
            child: wide ? _sideBySide(state) : _withSnapshot(state, _lists),
          ),
        ],
      ),
    ),
    bottomNavigationBar: wide ? null : _navigationBar(),
  );

  NavigationBar _navigationBar() => NavigationBar(
    selectedIndex: _tab,
    onDestinationSelected: (i) {
      if (i == _terminalDestination) {
        widget.onTerminal();
      } else {
        setState(() => _tab = i);
      }
    },
    destinations: const [
      NavigationDestination(
        icon: Icon(Icons.smart_toy_outlined),
        label: 'agents',
      ),
      NavigationDestination(
        icon: Icon(Icons.view_list_outlined),
        label: 'spaces',
      ),
      NavigationDestination(icon: Icon(Icons.terminal), label: 'terminal'),
    ],
  );

  /// The sidebar, and the open pane beside it.
  Widget _sideBySide(LinkState state) => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        width: 320,
        child: ColoredBox(
          color: Graphite.chrome,
          child: _withSnapshot(
            state,
            (snapshot) =>
                HerdrSidebar(snapshot, onOpen: _openPane, selected: _pane),
          ),
        ),
      ),
      const VerticalDivider(width: 1),
      Expanded(
        child: switch (_pane) {
          final pane? => _paneScreen(pane, wide: true),
          null => const Center(child: Text('Pick a pane')),
        },
      ),
    ],
  );

  /// [build] with the last known snapshot, dimmed while it may be out of
  /// date.
  Widget _withSnapshot(
    LinkState state,
    Widget Function(HerdrSnapshot snapshot) build,
  ) => ValueListenableBuilder(
    valueListenable: _link.snapshot,
    builder: (context, snapshot, _) {
      if (snapshot == null) {
        return switch (state) {
          LinkNoServer() || LinkFailed() => const SizedBox.shrink(),
          _ => const Center(child: CircularProgressIndicator()),
        };
      }
      return Opacity(
        opacity: state is LinkLive ? 1 : 0.5,
        child: build(snapshot),
      );
    },
  );

  Widget _lists(HerdrSnapshot snapshot) => _tab == 0
      ? AgentsList(snapshot, onOpen: _openPane)
      : SpacesList(snapshot, onOpen: _openPane);

  Widget _paneScreen(String paneId, {required bool wide}) => PaneScreen(
    key: _paneKey,
    draft: _drafts.putIfAbsent(paneId, TextEditingController.new),
    connection: _link,
    paneId: paneId,
    onShown: (shown) => widget.onPaneShown?.call(paneId, shown),
    onClose: wide ? null : _closePane,
    showLink: !wide,
    onDisconnect: widget.onDisconnect,
    server: widget.host.herdrKind.label,
    exactFirst: widget.host.herdrKind == HerdrKind.herdr,
    chatDetails: widget.chatDetails,
  );

  void _openPane(String paneId) {
    if (paneId == _pane) return;
    setState(() {
      _pane = paneId;
      _paneKey = GlobalKey();
    });
  }

  void _closePane() => setState(() => _pane = null);

  Widget? _banner(LinkState state) {
    final retry = ('Retry', _link.connect);
    return switch (state) {
      LinkOffline() || LinkConnecting() || LinkSyncing() || LinkLive() => null,
      LinkReconnecting(:final cause, retryAt: null) => StatusBanner(
        'No link. Retrying…',
        detail: '$cause',
      ),
      LinkReconnecting(:final cause, :final retryAt?) => _RetryBanner(
        key: ValueKey(retryAt),
        cause: cause,
        retryAt: retryAt,
        onNow: _link.connect,
      ),
      LinkNoServer(:final cause) => StatusBanner(
        '${widget.host.herdrKind.label} is not running on ${widget.host.label}.',
        detail: '$cause',
        action: retry,
      ),
      LinkFailed(cause: final SshConnectException error) => sshFailureBanner(
        error,
        retry,
      ),
      LinkFailed(:final cause) => StatusBanner(
        '${widget.host.herdrKind.label} on ${widget.host.label} sent something '
        'this app cannot read.',
        detail: '$cause',
        action: retry,
      ),
    };
  }
}

/// Counts down to the next attempt.
class _RetryBanner extends StatefulWidget {
  const _RetryBanner({
    super.key,
    required this.cause,
    required this.retryAt,
    required this.onNow,
  });

  final Object cause;
  final DateTime retryAt;
  final VoidCallback onNow;

  @override
  State<_RetryBanner> createState() => _RetryBannerState();
}

class _RetryBannerState extends State<_RetryBanner> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ms = widget.retryAt.difference(DateTime.now()).inMilliseconds;
    return StatusBanner(
      'No link. Retrying in ${max(0, (ms / 1000).ceil())} s.',
      detail: '${widget.cause}',
      action: ('Now', widget.onNow),
    );
  }
}
