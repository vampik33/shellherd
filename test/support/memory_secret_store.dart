import 'package:shellherd/ssh/secret_store.dart';

/// In-memory [SecretStore] for tests.
class MemorySecretStore implements SecretStore {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<Map<String, String>> readAll() async => Map.of(values);
}
