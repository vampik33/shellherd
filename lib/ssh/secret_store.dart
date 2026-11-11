import 'package:flutter/services.dart';
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
/// Service (libsecret) on Linux. Throws [SecretStoreException] when the
/// platform store fails.
class SecureSecretStore implements SecretStore {
  SecureSecretStore([this._storage = _secureStorage]);
  final FlutterSecureStorage _storage;

  /// The plugin wipes every saved key and password on Android when one
  /// fails to decrypt, unless told not to. A Keystore that cannot decrypt
  /// for a while, as after a restore from backup, must not cost the user
  /// their keys.
  static const _secureStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );

  @override
  Future<String?> read(String key) => _guard(() => _storage.read(key: key));

  @override
  Future<void> write(String key, String value) =>
      _guard(() => _storage.write(key: key, value: value));

  @override
  Future<void> delete(String key) => _guard(() => _storage.delete(key: key));

  @override
  Future<Map<String, String>> readAll() => _guard(_storage.readAll);

  static Future<T> _guard<T>(Future<T> Function() op) async {
    try {
      return await op();
    } on PlatformException catch (e) {
      throw SecretStoreException(e);
    }
  }
}

/// The platform store failed; with resetOnError off, nothing was deleted.
class SecretStoreException implements Exception {
  const SecretStoreException(this.cause);
  final Object cause;

  @override
  String toString() => 'SecretStoreException: $cause';
}
