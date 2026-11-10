import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where private keys live. In the app this is the platform keystore
/// ([SecureSecretStore]); tests use an in-memory map.
abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<Map<String, String>> readAll();
}

/// [SecretStore] on flutter_secure_storage: Android Keystore, or the Secret
/// Service (libsecret) on Linux.
class SecureSecretStore implements SecretStore {
  SecureSecretStore([this._storage = const FlutterSecureStorage()]);
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();
}
