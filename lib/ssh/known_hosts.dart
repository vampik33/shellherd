import 'json_file.dart';

/// A host key as dartssh2 shows it: the key type and the SHA256 fingerprint
/// text, `SHA256:<base64>`, the same text `ssh-keygen -l` prints.
///
/// dartssh2 gives only the fingerprint, not the key itself, so the store
/// cannot be an OpenSSH `known_hosts` file.
class HostKey {
  const HostKey(this.type, this.fingerprint);

  final String type;
  final String fingerprint;

  @override
  bool operator ==(Object other) =>
      other is HostKey &&
      other.type == type &&
      other.fingerprint == fingerprint;

  @override
  int get hashCode => Object.hash(type, fingerprint);

  @override
  String toString() => '$type $fingerprint';
}

/// The trusted key of each `address:port`, in `known_hosts.json`.
///
/// One key per address and port. A different key, also one of another
/// type, counts as a changed key.
class KnownHosts {
  KnownHosts(this._file);
  final JsonFile _file;

  /// The identity of a server here: two hosts with the same entry share
  /// one trusted key.
  static String entryOf(String address, int port) {
    final host = address.toLowerCase();
    return host.contains(':') ? '[$host]:$port' : '$host:$port';
  }

  Future<HostKey?> lookup(String address, int port) async =>
      _keyOf((await _file.read())[entryOf(address, port)]);

  static HostKey? _keyOf(Object? e) => e is Map<String, Object?>
      ? HostKey(e['type']! as String, e['fingerprint']! as String)
      : null;

  /// Trusts [key] only if no key is trusted yet for this address and port,
  /// in one serialized update. Returns the key trusted afterwards: [key],
  /// or the earlier key, which it never replaces. So two first-use prompts
  /// that run at once cannot swap a trusted key; only [forget] can.
  Future<HostKey> trust(String address, int port, HostKey key) async {
    late HostKey trusted;
    await _file.update((data) {
      final entry = entryOf(address, port);
      trusted = _keyOf(data[entry]) ?? key;
      data[entry] = {'type': trusted.type, 'fingerprint': trusted.fingerprint};
    });
    return trusted;
  }

  /// Removes the trusted key, so the next connection asks again. This is
  /// the only way past a changed key.
  Future<void> forget(String address, int port) =>
      _file.update((data) => data.remove(entryOf(address, port)));
}
