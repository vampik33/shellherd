import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:pinenacl/ed25519.dart' as ed25519;

import 'ids.dart';
import 'secret_store.dart';

/// The user's SSH private keys, kept in a [SecretStore] as unencrypted
/// OpenSSH PEM text under `ssh-key.<id>`. The keystore of the platform does
/// the encryption, so an imported key loses its passphrase once, here.
///
/// Also the login passwords of password hosts, under
/// `ssh-password.<host id>`.
class KeyStore {
  KeyStore(this._secrets);
  final SecretStore _secrets;

  static const _prefix = 'ssh-key.';
  static const _passwordPrefix = 'ssh-password.';

  /// Makes a new ed25519 key and returns its id.
  Future<String> generate({String comment = 'shellherd'}) async {
    final signing = ed25519.SigningKey.generate();
    final pair = OpenSSHEd25519KeyPair(
      signing.verifyKey.asTypedList,
      signing.asTypedList, // seed + public key, as OpenSSH stores it
      comment,
    );
    return _store(pair);
  }

  /// Imports a private key in PEM text (OpenSSH, PKCS#1 RSA or SEC1 EC) and
  /// returns its id. Throws [KeyImportException] when the text is not a key
  /// or [passphrase] is missing or wrong.
  Future<String> importPem(String pem, {String? passphrase}) async {
    final List<SSHKeyPair> pairs;
    try {
      pairs = SSHKeyPair.fromPem(pem, passphrase);
    } catch (e) {
      throw KeyImportException('$e');
    }
    if (pairs.isEmpty) throw const KeyImportException('no key in the text');
    return _store(pairs.first);
  }

  Future<String> _store(SSHKeyPair pair) async {
    final id = randomId();
    await _secrets.write('$_prefix$id', pair.toPem());
    return id;
  }

  /// The ids of all stored keys.
  Future<List<String>> ids() async => [
    for (final k in (await _secrets.readAll()).keys)
      if (k.startsWith(_prefix)) k.substring(_prefix.length),
  ];

  /// The key pair for SSHClient(identities: ...).
  Future<List<SSHKeyPair>> identities(String id) async =>
      SSHKeyPair.fromPem(await _pem(id));

  /// The line for `~/.ssh/authorized_keys`: "ssh-ed25519 AAAA... comment".
  Future<String> publicLine(String id) async {
    final pair = (await identities(id)).first;
    final blob = base64Encode(pair.toPublicKey().encode());
    final comment = pair is OpenSSHKeyPair ? pair.comment : null;
    return [pair.name, blob, ?comment].join(' ').trim();
  }

  Future<void> delete(String id) => _secrets.delete('$_prefix$id');

  /// The saved password of host [hostId], or null.
  Future<String?> password(String hostId) =>
      _secrets.read('$_passwordPrefix$hostId');

  Future<void> savePassword(String hostId, String password) =>
      _secrets.write('$_passwordPrefix$hostId', password);

  Future<void> deletePassword(String hostId) =>
      _secrets.delete('$_passwordPrefix$hostId');

  Future<String> _pem(String id) async =>
      await _secrets.read('$_prefix$id') ??
      (throw StateError('no SSH key with id $id'));
}

class KeyImportException implements Exception {
  const KeyImportException(this.message);
  final String message;

  @override
  String toString() => 'KeyImportException: $message';
}
