import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../herdr/herdr_connection.dart';
import '../herdr/ui/herdr_screen.dart';
import '../notify/notifier.dart';
import '../ssh/host.dart';
import '../terminal/terminal_screen.dart';
import 'host_form_screen.dart';
import 'host_status.dart';
import 'palette.dart';

/// The home screen: the saved PCs. A tap opens the herdr session.
class HostListScreen extends StatefulWidget {
  const HostListScreen(this.services, {super.key});

  final AppServices services;

  @override
  State<HostListScreen> createState() => _HostListScreenState();
}

class _HostListScreenState extends State<HostListScreen> {
  List<Host>? _hosts;
  Object? _error;

  /// The last answer of the probe, by `address:port`.
  final _online = <String, bool>{};

  /// Counts the reads of the hosts, so an older one that ends last is
  /// dropped.
  int _loads = 0;

  /// Counts the probe rounds, so a late answer of an old one is dropped.
  int _round = 0;

  late final Timer _ticker;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(widget.services.probeEvery, (_) => _probe());
    _lifecycle = AppLifecycleListener(onResume: _probe);
    widget.services.hostsChanged.addListener(_reload);
    _load();
  }

  @override
  void dispose() {
    _round++;
    widget.services.hostsChanged.removeListener(_reload);
    _ticker.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  static String _endpoint(Host host) => '${host.address}:${host.port}';

  /// Checks each connected host, while the list is on screen and the app
  /// in front.
  void _probe() {
    final hosts = _hosts;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!mounted ||
        hosts == null ||
        !(ModalRoute.of(context)?.isCurrent ?? true) ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      return;
    }
    final round = ++_round;
    for (final host in hosts) {
      if (host.disconnected) continue;
      final endpoint = _endpoint(host);
      unawaited(
        widget.services.probeHost(host.address, host.port).then((online) {
          if (mounted && round == _round) {
            setState(() => _online[endpoint] = online);
          }
        }),
      );
    }
  }

  HostStatus _status(Host host) {
    if (host.disconnected) return HostStatus.disconnected;
    return switch (_online[_endpoint(host)]) {
      true => HostStatus.online,
      false => HostStatus.offline,
      null => HostStatus.unknown,
    };
  }

  void _reload() => unawaited(_load());

  Future<void> _load() async {
    final load = ++_loads;
    try {
      final hosts = await widget.services.hosts.list();
      if (mounted && load == _loads) {
        setState(() {
          _hosts = hosts;
          _error = null;
        });
        _probe();
      }
    } catch (e) {
      // A damaged file is not an empty list: saving now would replace it.
      if (mounted && load == _loads) setState(() => _error = e);
    }
  }

  Future<void> _openForm([Host? host]) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HostFormScreen(widget.services, host: host),
      ),
    );
    await _load();
  }

  Future<void> _openTerminal(Host host) async {
    await Navigator.of(context).push(terminalRoute(widget.services, host));
    await _load();
  }

  Future<void> _openHerdr(Host host) async {
    await Navigator.of(context).push(herdrRoute(widget.services, host));
    await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('shellherd')),
    floatingActionButton: _error != null
        ? null
        : FloatingActionButton(
            tooltip: 'Add host',
            onPressed: _openForm,
            child: const Icon(Icons.add),
          ),
    body: _body(),
  );

  Widget _body() {
    if (_error case final error?) {
      return _Message('Cannot read the saved hosts.\n$error');
    }
    final hosts = _hosts;
    if (hosts == null) return const Center(child: CircularProgressIndicator());
    if (hosts.isEmpty) return const _Message('No hosts yet. Add your PC.');
    return ListView(
      children: [
        for (final host in hosts)
          ListTile(
            leading: HostStatusDot(host.label, _status(host)),
            title: Text(host.label),
            subtitle: Text(
              '${host.user}@${host.address}'
              '${host.port == 22 ? '' : ':${host.port}'}',
              style: const TextStyle(fontFamily: monoFont),
            ),
            onTap: () => _openHerdr(host),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.terminal),
                  tooltip: 'Terminal on ${host.label}',
                  onPressed: () => _openTerminal(host),
                ),
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Edit ${host.label}',
                  onPressed: () => _openForm(host),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The plain terminal of [host]: over mosh when the host has it on.
/// Opening it connects a disconnected host again.
Route<void> terminalRoute(AppServices services, Host host) {
  unawaited(services.setDisconnected(host.id, false));
  return MaterialPageRoute<void>(
    builder: (_) => TerminalScreen(
      host: host,
      connector: services.connector,
      mosh: host.mosh,
      onDisconnect: () => unawaited(services.setDisconnected(host.id, true)),
    ),
  );
}

/// The herdr session of [host]; with [openPane], that pane open in it.
/// Opening it connects a disconnected host again.
Route<void> herdrRoute(AppServices services, Host host, {String? openPane}) {
  unawaited(services.setDisconnected(host.id, false));
  return MaterialPageRoute<void>(
    builder: (context) => HerdrScreen(
      host: host,
      createConnection: () =>
          HerdrConnection(sshLinkOpener(services.connector, host)),
      onTerminal: () =>
          Navigator.of(context).push(terminalRoute(services, host)),
      openPane: openPane,
      onPaneShown: (paneId, shown) =>
          services.notify.paneShown(PaneTarget(host.id, paneId), shown),
      onDisconnect: () => unawaited(services.setDisconnected(host.id, true)),
    ),
  );
}

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: SelectableText(text, textAlign: TextAlign.center),
    ),
  );
}
