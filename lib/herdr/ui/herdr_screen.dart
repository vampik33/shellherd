import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../ssh/host.dart';
import '../../ssh/ssh_connector.dart';
import '../../ui/link_status.dart';
import '../api/herdr_client.dart';
import '../herdr_connection.dart';
import 'herdr_lists.dart';
import 'link_chip.dart';
import 'pane_screen.dart';

/// The herdr session of one PC, as phone lists.
class HerdrScreen extends StatefulWidget {
  const HerdrScreen({
    super.key,
    required this.host,
    required this.createConnection,
    required this.onTerminal,
    this.openPane,
    this.onPaneShown,
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

  @override
  State<HerdrScreen> createState() => _HerdrScreenState();
}

class _HerdrScreenState extends State<HerdrScreen> {
  /// The last item of the bar is no tab: it opens the terminal on top.
  static const _terminalDestination = 2;

  late final HerdrConnection _link;
  var _tab = 0;

  @override
  void initState() {
    super.initState();
    _link = widget.createConnection()..connect();
    if (widget.openPane case final paneId?) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openPane(paneId);
      });
    }
  }

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  String get _title => switch (widget.host.herdrSession) {
    final session? => '${widget.host.label} · $session',
    null => widget.host.label,
  };

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: _link.state,
    builder: (context, state, _) => Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [herdrLinkChip(state), const SizedBox(width: 8)],
      ),
      body: SafeArea(
        child: Column(
          children: [
            ?_banner(state),
            Expanded(
              child: ValueListenableBuilder(
                valueListenable: _link.snapshot,
                builder: (context, snapshot, _) => _lists(state, snapshot),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
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
      ),
    ),
  );

  Widget _lists(LinkState state, HerdrSnapshot? snapshot) {
    if (snapshot == null) {
      return switch (state) {
        LinkNoServer() || LinkFailed() => const SizedBox.shrink(),
        _ => const Center(child: CircularProgressIndicator()),
      };
    }
    // The last known state, dimmed while it may be out of date.
    return Opacity(
      opacity: state is LinkLive ? 1 : 0.5,
      child: _tab == 0
          ? AgentsList(snapshot, onOpen: _openPane)
          : SpacesList(snapshot, onOpen: _openPane),
    );
  }

  void _openPane(String paneId) => unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PaneScreen(
          connection: _link,
          paneId: paneId,
          onShown: (shown) => widget.onPaneShown?.call(paneId, shown),
        ),
      ),
    ),
  );

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
        'herdr is not running on ${widget.host.label}.',
        detail: '$cause',
        action: retry,
      ),
      LinkFailed(cause: final SshConnectException error) => sshFailureBanner(
        error,
        retry,
      ),
      LinkFailed(:final cause) => StatusBanner(
        'herdr on ${widget.host.label} sent something this app cannot read.',
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
