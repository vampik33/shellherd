import 'package:flutter/material.dart';

import '../app.dart';
import '../ssh/host.dart';
import '../terminal/terminal_screen.dart';
import 'host_form_screen.dart';

/// The home screen: the saved PCs. A tap opens the terminal.
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

  void _openTerminal(Host host) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          TerminalScreen(host: host, connector: widget.services.connector),
    ),
  );

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
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            onTap: () => _openTerminal(host),
            trailing: IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit ${host.label}',
              onPressed: () => _openForm(host),
            ),
          ),
      ],
    );
  }
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
