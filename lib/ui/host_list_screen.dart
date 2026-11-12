import 'package:flutter/material.dart';

import '../app.dart';
import '../herdr/herdr_connection.dart';
import '../herdr/ui/herdr_screen.dart';
import '../notify/notifier.dart';
import '../ssh/host.dart';
import '../terminal/terminal_screen.dart';
import 'host_form_screen.dart';
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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final hosts = await widget.services.hosts.list();
      if (mounted) {
        setState(() {
          _hosts = hosts;
          _error = null;
        });
      }
    } catch (e) {
      // A damaged file is not an empty list: saving now would replace it.
      if (mounted) setState(() => _error = e);
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

  void _openTerminal(Host host) =>
      Navigator.of(context).push(terminalRoute(widget.services, host));

  void _openHerdr(Host host) =>
      Navigator.of(context).push(herdrRoute(widget.services, host));

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
Route<void> terminalRoute(AppServices services, Host host) =>
    MaterialPageRoute<void>(
      builder: (_) => TerminalScreen(
        host: host,
        connector: services.connector,
        mosh: host.mosh,
      ),
    );

/// The herdr session of [host]; with [openPane], that pane open in it.
Route<void> herdrRoute(AppServices services, Host host, {String? openPane}) =>
    MaterialPageRoute<void>(
      builder: (context) => HerdrScreen(
        host: host,
        createConnection: () =>
            HerdrConnection(sshLinkOpener(services.connector, host)),
        onTerminal: () =>
            Navigator.of(context).push(terminalRoute(services, host)),
        openPane: openPane,
        onPaneShown: (paneId, shown) =>
            services.notify.paneShown(PaneTarget(host.id, paneId), shown),
      ),
    );

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
