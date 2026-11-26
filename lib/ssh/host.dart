import 'json_file.dart';

/// How a host logs in. [tailscale] sends no key and no password: Tailscale
/// SSH on the PC knows the phone by its tailnet identity. The phone needs
/// the Tailscale app connected.
enum SshAuth { key, password, tailscale }

/// Which server runs the agents of a PC.
enum HerdrKind {
  /// The `herdr` terminal multiplexer.
  herdr('herdr'),

  /// The Herdr desktop app, through its core, herdr-core.
  herdrApp('Herdr app');

  const HerdrKind(this.label);

  /// The name the user knows it by.
  final String label;
}

/// One saved PC. It holds no secret: the private key lives in the
/// [KeyStore] under [keyId], a password in the [KeyStore] under [id].
class Host {
  Host({
    required this.id,
    required this.label,
    required this.address,
    this.port = 22,
    required this.user,
    this.auth = SshAuth.key,
    this.keyId,
    this.herdrKind = HerdrKind.herdr,
    this.herdrSession,
    this.herdrSocket,
    this.mosh = false,
    this.moshServer = defaultMoshServer,
    this.notify = false,
    this.disconnected = false,
  }) {
    if (label.isEmpty || address.isEmpty || user.isEmpty) {
      throw ArgumentError('label, address and user must not be empty');
    }
    if (port < 1 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'not a TCP port');
    }
    if ((auth == SshAuth.key) != (keyId != null)) {
      throw ArgumentError('a key host needs a keyId, other hosts none');
    }
  }

  factory Host.fromJson(Map<String, Object?> j) => Host(
    id: j['id']! as String,
    label: j['label']! as String,
    address: j['address']! as String,
    port: j['port']! as int,
    user: j['user']! as String,
    // Hosts saved before passwords came are key hosts.
    auth: SshAuth.values.byName(j['auth'] as String? ?? SshAuth.key.name),
    keyId: j['keyId'] as String?,
    // Hosts saved before the Herdr app came use herdr.
    herdrKind: HerdrKind.values.byName(
      j['herdrKind'] as String? ?? HerdrKind.herdr.name,
    ),
    herdrSession: j['herdrSession'] as String?,
    herdrSocket: j['herdrSocket'] as String?,
    mosh: j['mosh']! as bool,
    moshServer: j['moshServer']! as String,
    notify: j['notify'] as bool? ?? false,
    // Hosts saved before Disconnect came are connected.
    disconnected: j['disconnected'] as bool? ?? false,
  );

  final String id;

  /// The name on the home screen, for example "workbox".
  final String label;

  /// DNS name or IP address.
  final String address;
  final int port;
  final String user;
  final SshAuth auth;

  /// The private key of a key host; null for the others.
  final String? keyId;

  final HerdrKind herdrKind;

  /// The session name of herdr or of herdr-core; null means the default
  /// session.
  final String? herdrSession;

  /// Overrides the socket path that the link finds by itself.
  final String? herdrSocket;

  /// The plain terminal runs over mosh instead of SSH.
  final bool mosh;
  final String moshServer;

  static const defaultMoshServer = 'mosh-server';

  /// Watch the agents of this host in the background and notify when one
  /// needs the user or is done.
  final bool notify;

  /// The user pressed Disconnect: nothing connects to the host in the
  /// background until the user opens it again.
  final bool disconnected;

  /// The background watcher connects to this host.
  bool get watched => notify && !disconnected;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'address': address,
    'port': port,
    'user': user,
    'auth': auth.name,
    'keyId': ?keyId,
    'herdrKind': herdrKind.name,
    'herdrSession': ?herdrSession,
    'herdrSocket': ?herdrSocket,
    'mosh': mosh,
    'moshServer': moshServer,
    'notify': notify,
    'disconnected': disconnected,
  };
}

/// The saved hosts, in the order the user added them, in `hosts.json`.
class HostStore {
  HostStore(this._file);
  final JsonFile _file;

  Future<List<Host>> list() async {
    final hosts = (await _file.read())['hosts'] as List<Object?>? ?? const [];
    return [for (final h in hosts) Host.fromJson(h! as Map<String, Object?>)];
  }

  Future<Host?> get(String id) async =>
      (await list()).where((h) => h.id == id).firstOrNull;

  /// Adds [host], or replaces the saved host with the same id in place.
  /// A replaced host keeps its saved [Host.disconnected]: only
  /// [setDisconnected] changes it, so that a save from a copy read before a
  /// Disconnect or an open does not undo it. A new host is saved as it is.
  Future<void> save(Host host) => _file.update((data) {
    final hosts = [...?(data['hosts'] as List<Object?>?)];
    final i = hosts.indexWhere((h) => (h! as Map)['id'] == host.id);
    final json = host.toJson();
    if (i < 0) {
      hosts.add(json);
    } else {
      final saved = hosts[i]! as Map;
      json['disconnected'] = saved['disconnected'] as bool? ?? false;
      hosts[i] = json;
    }
    data['hosts'] = hosts;
  });

  /// Sets [Host.disconnected] of the saved host [id] in place. True if it
  /// changed; false if it was already so or there is no such host, and then
  /// the file is not written.
  Future<bool> setDisconnected(String id, bool value) =>
      _file.updateIf((data) {
        final host = [
          for (final h in data['hosts'] as List<Object?>? ?? const [])
            h! as Map<String, Object?>,
        ].where((h) => h['id'] == id).firstOrNull;
        if (host == null || (host['disconnected'] as bool? ?? false) == value) {
          return false;
        }
        host['disconnected'] = value;
        return true;
      });

  Future<void> remove(String id) => _file.update((data) {
    final hosts = data['hosts'] as List<Object?>?;
    hosts?.removeWhere((h) => (h! as Map)['id'] == id);
  });
}
