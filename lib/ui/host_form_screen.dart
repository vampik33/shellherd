import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../ssh/host.dart';
import '../ssh/ids.dart';
import '../ssh/key_store.dart';
import '../ssh/known_hosts.dart';
import 'confirm_dialog.dart';

/// Adds a host, or edits [host].
///
/// Each host logs in with its own key or with a password. A key made here
/// belongs to the form until Save; leaving the form deletes it. Save
/// deletes the key or the password that the host no longer uses.
class HostFormScreen extends StatefulWidget {
  const HostFormScreen(this.services, {super.key, this.host});

  final AppServices services;
  final Host? host;

  @override
  State<HostFormScreen> createState() => _HostFormScreenState();
}

class _HostFormScreenState extends State<HostFormScreen> {
  final _form = GlobalKey<FormState>();
  late final _label = TextEditingController(text: widget.host?.label);
  late final _address = TextEditingController(text: widget.host?.address);
  late final _port = TextEditingController(text: '${widget.host?.port ?? 22}');
  late final _user = TextEditingController(text: widget.host?.user);
  late bool _notify = widget.host?.notify ?? false;
  late bool _mosh = widget.host?.mosh ?? false;
  late final _moshServer = TextEditingController(
    text: widget.host?.moshServer ?? Host.defaultMoshServer,
  );

  /// Also where the password is saved, before the host is.
  late final _id = widget.host?.id ?? randomId();
  late SshAuth _auth = widget.host?.auth ?? SshAuth.key;

  /// A new password; empty keeps the saved one.
  final _password = TextEditingController();
  bool _hasPassword = false;

  ({String id, String line})? _key;

  /// Keys made in this form that no host owns and that are not deleted yet.
  final _unsavedKeys = <String>{};
  String? _keyError;
  HostKey? _trusted;

  /// A key or file operation runs; the screen must not close under it.
  bool _busy = false;

  /// The saved key is still loading. The user can leave, but no action may
  /// run: the load would overwrite a key chosen in the meantime.
  late bool _loading = widget.host != null;

  bool get _locked => _busy || _loading;

  AppServices get _services => widget.services;

  @override
  void initState() {
    super.initState();
    if (widget.host case final host?) _loadSaved(host);
  }

  Future<void> _loadSaved(Host host) async {
    String? line;
    if (host.keyId case final keyId?) {
      try {
        line = await _services.keys.publicLine(keyId);
      } catch (_) {
        // The key is gone or damaged: the user makes a new one here.
      }
    }
    var hasPassword = false;
    if (host.auth == SshAuth.password) {
      try {
        hasPassword = await _services.keys.password(host.id) != null;
      } catch (_) {
        // Unreadable: the user types it again.
      }
    }
    HostKey? trusted;
    try {
      trusted = await _services.knownHosts.lookup(host.address, host.port);
    } catch (_) {
      // Without the list the form only hides the Forget button.
    }
    if (!mounted) return;
    setState(() {
      if (host.keyId case final keyId?) {
        if (line == null) {
          _keyError = 'The saved key is missing. Make a new one.';
        } else {
          _key = (id: keyId, line: line);
        }
      }
      _hasPassword = hasPassword;
      _trusted = trusted;
      _loading = false;
    });
  }

  @override
  void dispose() {
    for (final key in _unsavedKeys) {
      _services.keys.delete(key).ignore();
    }
    _label.dispose();
    _address.dispose();
    _port.dispose();
    _user.dispose();
    _moshServer.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Runs [action] with the screen locked and shows a failure.
  Future<void> _run(String failure, Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) _snack('$failure: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm(String title, String text, String action) =>
      confirmDialog(context, title: title, content: Text(text), action: action);

  void _snack(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<bool> _mayReplaceKey() async =>
      _key == null ||
      await _confirm(
        'Replace the key?',
        'The PC does not know a new key. '
            'You must add its public line to the PC again.',
        'Replace',
      );

  /// Makes the new key [id] the key of this form. A failure leaves the
  /// previous key selected, and every key still on the delete list.
  Future<void> _useKey(String id) async {
    _unsavedKeys.add(id); // first, so that leaving the form deletes it
    final line = await _services.keys.publicLine(id);
    setState(() {
      _key = (id: id, line: line);
      _keyError = null;
    });
    for (final key in _unsavedKeys.where((k) => k != id).toList()) {
      await _services.keys.delete(key);
      _unsavedKeys.remove(key);
    }
  }

  Future<void> _generate() async {
    if (!await _mayReplaceKey()) return;
    await _run(
      'Cannot store the key',
      () async => _useKey(await _services.keys.generate()),
    );
  }

  Future<void> _import() async {
    if (!await _mayReplaceKey() || !mounted) return;
    final id = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ImportKeyDialog(_services.keys),
    );
    if (id != null) await _run('Cannot read the key', () => _useKey(id));
  }

  Future<void> _copyPublicLine() async {
    await Clipboard.setData(ClipboardData(text: _key!.line));
    if (!mounted) return;
    _snack('Public line copied.');
  }

  Future<void> _save() async {
    final valid = _form.currentState!.validate();
    final byKey = _auth == SshAuth.key;
    final keyId = byKey ? _key?.id : null;
    final missingKey = byKey && keyId == null;
    if (missingKey) {
      setState(() => _keyError = 'Generate or import a key first.');
    }
    if (!valid || missingKey) return;
    await _run('Cannot save the host', () async {
      final old = widget.host;
      final moshServer = _moshServer.text.trim();
      final password = byKey ? '' : _password.text;
      // First, so that no saved host lacks its password. A failed save puts
      // the previous one back: the old host must not get the new password.
      String? previous;
      if (password.isNotEmpty) {
        if (old != null) previous = await _services.keys.password(_id);
        await _services.keys.savePassword(_id, password);
      }
      try {
        await _services.hosts.save(
          Host(
            id: _id,
            label: _label.text.trim(),
            address: _address.text.trim(),
            port: int.parse(_port.text.trim()),
            user: _user.text.trim(),
            auth: _auth,
            keyId: keyId,
            herdrSession: old?.herdrSession,
            herdrSocket: old?.herdrSocket,
            mosh: _mosh,
            moshServer: moshServer.isEmpty
                ? Host.defaultMoshServer
                : moshServer,
            notify: _notify,
          ),
        );
      } catch (_) {
        if (password.isNotEmpty) {
          await (previous == null
                  ? _services.keys.deletePassword(_id)
                  : _services.keys.savePassword(_id, previous))
              .catchError((Object _) {});
        }
        rethrow;
      }
      _unsavedKeys.remove(keyId); // the host owns it now
      if (old?.keyId case final oldKey? when oldKey != keyId) {
        await _services.keys.delete(oldKey);
      }
      if (byKey) await _services.keys.deletePassword(_id);
      await _syncNotify(ask: _notify);
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _delete() async {
    final host = widget.host!;
    if (!await _confirm(
      'Remove ${host.label}?',
      'This also deletes its private key from this device.',
      'Remove',
    )) {
      return;
    }
    await _run('Cannot remove the host', () async {
      await _services.removeHost(host);
      await _syncNotify();
      if (mounted) Navigator.of(context).pop();
    });
  }

  /// The host is saved already, so a failure here only tells the user.
  Future<void> _syncNotify({bool ask = false}) async {
    try {
      if (!await _services.notify.sync(ask: ask) && ask && mounted) {
        _snack('Notifications are off for shellherd in the system settings.');
      }
    } catch (e) {
      if (mounted) _snack('Cannot watch the agents: $e');
    }
  }

  Future<void> _forgetTrusted() async {
    final host = widget.host!;
    if (!await _confirm(
      'Forget the server key?',
      'The next connection asks you to trust the key the server shows then. '
          'Do this only if you know why the key changed.',
      'Forget',
    )) {
      return;
    }
    await _run('Cannot forget the key', () async {
      await _services.knownHosts.forget(host.address, host.port);
      if (mounted) setState(() => _trusted = null);
    });
  }

  static String? _required(String? v) =>
      v == null || v.trim().isEmpty ? 'Required' : null;

  static String? _validPort(String? v) {
    final port = int.tryParse(v?.trim() ?? '');
    return port == null || port < 1 || port > 65535 ? '1 to 65535' : null;
  }

  Widget _field(
    String label,
    TextEditingController controller,
    String? Function(String?) validator, {
    String? hint,
    TextInputType? keyboard,
  }) => TextFormField(
    controller: controller,
    validator: validator,
    keyboardType: keyboard,
    autocorrect: false,
    enableSuggestions: false,
    textInputAction: TextInputAction.next,
    decoration: InputDecoration(labelText: label, hintText: hint),
  );

  @override
  Widget build(BuildContext context) {
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 12);
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.host == null ? 'Add host' : 'Edit host'),
          actions: [
            if (widget.host != null)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remove host',
                onPressed: _locked ? null : _delete,
              ),
            TextButton(
              onPressed: _locked ? null : _save,
              child: const Text('Save'),
            ),
          ],
        ),
        body: Form(
          key: _form,
          // Not a ListView: Form.validate skips fields that a list has
          // scrolled out and disposed.
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _field('Label', _label, _required, hint: 'workbox'),
                _field(
                  'Address',
                  _address,
                  _required,
                  hint: 'DNS name or IP address',
                  keyboard: TextInputType.url,
                ),
                _field(
                  'Port',
                  _port,
                  _validPort,
                  keyboard: TextInputType.number,
                ),
                _field('User', _user, _required),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Notify'),
                  subtitle: const Text('When an agent needs you or is done.'),
                  value: _notify,
                  onChanged: _locked
                      ? null
                      : (v) => setState(() => _notify = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Mosh'),
                  subtitle: const Text(
                    'A terminal that lives through sleep and network changes. '
                    'The PC needs mosh-server and open UDP ports.',
                  ),
                  value: _mosh,
                  onChanged: _locked ? null : (v) => setState(() => _mosh = v),
                ),
                if (_mosh)
                  TextFormField(
                    controller: _moshServer,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'mosh-server command',
                      helperText: 'A path if it is not on the PATH of the PC.',
                    ),
                  ),
                const SizedBox(height: 24),
                Text('Login', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                SegmentedButton<SshAuth>(
                  segments: const [
                    ButtonSegment(value: SshAuth.key, label: Text('SSH key')),
                    ButtonSegment(
                      value: SshAuth.password,
                      label: Text('Password'),
                    ),
                  ],
                  selected: {_auth},
                  onSelectionChanged: _locked
                      ? null
                      : (v) => setState(() => _auth = v.single),
                ),
                const SizedBox(height: 8),
                if (_auth == SshAuth.password)
                  TextFormField(
                    controller: _password,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.visiblePassword,
                    validator: (v) =>
                        (v ?? '').isEmpty && !_hasPassword ? 'Required' : null,
                    decoration: InputDecoration(
                      labelText: 'Password',
                      helperText: _hasPassword
                          ? 'Saved. Leave empty to keep it.'
                          : 'Kept in the keystore of this device.',
                    ),
                  )
                else ...[
                  if (_keyError case final error?)
                    Text(
                      error,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (_key?.line case final line?) ...[
                    const Text(
                      'Add this line to ~/.ssh/authorized_keys on the PC:',
                    ),
                    const SizedBox(height: 8),
                    SelectableText(line, style: mono),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        icon: const Icon(Icons.copy, size: 18),
                        label: const Text('Copy'),
                        onPressed: _copyPublicLine,
                      ),
                    ),
                  ],
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: _locked ? null : _generate,
                        child: const Text('Generate key'),
                      ),
                      OutlinedButton(
                        onPressed: _locked ? null : _import,
                        child: const Text('Import key'),
                      ),
                    ],
                  ),
                ],
                if (_trusted case final trusted?) ...[
                  const SizedBox(height: 24),
                  Text(
                    'Trusted server key',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  SelectableText('$trusted', style: mono),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _locked ? null : _forgetTrusted,
                      child: const Text('Forget server key'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Reads a pasted private key and stores it. Pops with the new key id.
class _ImportKeyDialog extends StatefulWidget {
  const _ImportKeyDialog(this.keys);
  final KeyStore keys;

  @override
  State<_ImportKeyDialog> createState() => _ImportKeyDialogState();
}

class _ImportKeyDialogState extends State<_ImportKeyDialog> {
  final _pem = TextEditingController();
  final _passphrase = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _pem.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final passphrase = _passphrase.text;
    try {
      final id = await widget.keys.importPem(
        _pem.text.trim(),
        passphrase: passphrase.isEmpty ? null : passphrase,
      );
      if (mounted) Navigator.pop(context, id);
    } on KeyImportException {
      // Not the parser's message: it can quote the pasted key.
      _fail('This is not a private key, or the passphrase is wrong.');
    } catch (e) {
      _fail('Cannot store the key: $e');
    }
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: AlertDialog(
      title: const Text('Import key'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _pem,
              minLines: 4,
              maxLines: 8,
              autocorrect: false,
              enableSuggestions: false,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                labelText: 'Private key (PEM text)',
              ),
            ),
            TextField(
              controller: _passphrase,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Passphrase, if it has one',
              ),
            ),
            if (_error case final error?)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: const Text('Import'),
        ),
      ],
    ),
  );
}
