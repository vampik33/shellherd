import 'json_file.dart';

/// One saved PC. It holds no secret: the private key lives in the
/// [KeyStore] under [keyId].
class Host {
  Host({
    required this.id,
    required this.label,
    required this.address,
    this.port = 22,
    required this.user,
    required this.keyId,
    this.herdrSession,
    this.herdrSocket,
    this.mosh = false,
    this.moshServer = 'mosh-server',
  }) {
    if (label.isEmpty || address.isEmpty || user.isEmpty) {
      throw ArgumentError('label, address and user must not be empty');
    }
    if (port < 1 || port > 65535) {
      throw ArgumentError.value(port, 'port', 'not a TCP port');
    }
  }

  factory Host.fromJson(Map<String, Object?> j) => Host(
    id: j['id']! as String,
    label: j['label']! as String,
    address: j['address']! as String,
    port: j['port']! as int,
    user: j['user']! as String,
    keyId: j['keyId']! as String,
    herdrSession: j['herdrSession'] as String?,
    herdrSocket: j['herdrSocket'] as String?,
    mosh: j['mosh']! as bool,
    moshServer: j['moshServer']! as String,
  );

  final String id;

  /// The name on the home screen, for example "workbox".
  final String label;

  /// DNS name or IP address.
  final String address;
  final int port;
  final String user;
  final String keyId;

  /// The herdr session name; null means the default session.
  final String? herdrSession;

  /// Overrides the herdr socket path that the link finds by itself.
  final String? herdrSocket;

  /// Show the mosh button for the plain terminal.
  final bool mosh;
  final String moshServer;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'address': address,
    'port': port,
    'user': user,
    'keyId': keyId,
    'herdrSession': ?herdrSession,
    'herdrSocket': ?herdrSocket,
    'mosh': mosh,
    'moshServer': moshServer,
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
  Future<void> save(Host host) => _file.update((data) {
    final hosts = [...?(data['hosts'] as List<Object?>?)];
    final i = hosts.indexWhere((h) => (h! as Map)['id'] == host.id);
    if (i < 0) {
      hosts.add(host.toJson());
    } else {
      hosts[i] = host.toJson();
    }
    data['hosts'] = hosts;
  });

  Future<void> remove(String id) => _file.update((data) {
    final hosts = data['hosts'] as List<Object?>?;
    hosts?.removeWhere((h) => (h! as Map)['id'] == id);
  });
}
