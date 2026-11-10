import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';

import 'host.dart';
import 'key_store.dart';
import 'known_hosts.dart';

/// Asks the user whether to trust [key], the first key seen for [host].
typedef TrustPrompt = Future<bool> Function(Host host, HostKey key);

/// Opens authenticated SSH connections to saved hosts. The terminal, herdr
/// and the watcher all connect through it.
///
/// Host keys: trust on first use, stop on a changed key. The first
/// connection to a new host only reads its key and closes; the user decides
/// with no handshake timer running, and a trusted key is checked again on a
/// second connection.
class SshConnector {
  SshConnector({
    required this.knownHosts,
    required this.keys,
    required this.askTrust,
    this.timeout = const Duration(seconds: 15),
  });

  final KnownHosts knownHosts;
  final KeyStore keys;
  final TrustPrompt askTrust;

  /// For each of TCP connect, handshake and login.
  final Duration timeout;

  /// Throws a [SshConnectException]. The caller closes the client.
  Future<SSHClient> open(Host host) async {
    final known = await knownHosts.lookup(host.address, host.port);
    if (known != null) return _connect(host, known);

    final presented = await _readHostKey(host);
    if (!await askTrust(host, presented)) {
      throw SshHostKeyRejected(host, presented);
    }
    // Another open() may have trusted a different key while this prompt
    // was open; that key wins, as any trusted key does.
    final trusted = await knownHosts.trust(host.address, host.port, presented);
    if (trusted != presented) {
      throw SshHostKeyChanged(host, trusted, presented);
    }
    return _connect(host, presented);
  }

  /// Connects only as far as the host key, then closes.
  Future<HostKey> _readHostKey(Host host) async {
    try {
      (await _client(host, const [], null)).close(); // never logs in
    } on _HostKeySeen catch (e) {
      return e.key;
    }
    throw SshNetworkException(host, 'no host key');
  }

  /// Connects and logs in, if the server shows [expected].
  Future<SSHClient> _connect(Host host, HostKey expected) async {
    final List<SSHKeyPair> identities;
    try {
      identities = await keys.identities(host.keyId);
    } catch (e) {
      throw SshAuthFailed(host, e); // the saved key is gone or unreadable
    }
    return _client(host, identities, expected);
  }

  /// Accepts only the host key [expected]. With [expected] null it rejects
  /// every key and throws [_HostKeySeen] with the key the server showed.
  Future<SSHClient> _client(
    Host host,
    List<SSHKeyPair> identities,
    HostKey? expected,
  ) async {
    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(
        host.address,
        host.port,
        timeout: timeout,
      );
    } catch (e) {
      throw SshNetworkException(host, e);
    }
    HostKey? seen;
    final client = SSHClient(
      socket,
      username: host.user,
      identities: identities,
      // dartssh2 gives the fingerprint as the text "SHA256:<base64>".
      onVerifyHostKey: (type, fp) {
        seen = HostKey(type, utf8.decode(fp));
        return seen == expected;
      },
      handshakeTimeout: timeout,
      authTimeout: timeout,
    );
    try {
      await client.authenticated;
      return client;
    } on SSHAuthFailError catch (e) {
      client.close();
      throw SshAuthFailed(host, e);
    } catch (e) {
      client.close();
      if (seen case final key? when key != expected) {
        throw expected == null
            ? _HostKeySeen(key)
            : SshHostKeyChanged(host, expected, key);
      }
      throw SshNetworkException(host, e);
    }
  }
}

/// The first-use read got the host key; [SshConnector.open] asks about it.
class _HostKeySeen implements Exception {
  const _HostKeySeen(this.key);
  final HostKey key;
}

/// Everything [SshConnector.open] throws.
sealed class SshConnectException implements Exception {
  const SshConnectException(this.host);
  final Host host;
}

/// The server shows a key other than the trusted one. The app offers no way
/// to continue; the user must forget the old key on purpose.
class SshHostKeyChanged extends SshConnectException {
  const SshHostKeyChanged(super.host, this.trusted, this.presented);
  final HostKey trusted;
  final HostKey presented;

  @override
  String toString() =>
      'SshHostKeyChanged(${host.address}:${host.port}): '
      'trusted $trusted, server shows $presented';
}

/// The user did not trust the key of a new host.
class SshHostKeyRejected extends SshConnectException {
  const SshHostKeyRejected(super.host, this.presented);
  final HostKey presented;

  @override
  String toString() => 'SshHostKeyRejected(${host.address}): $presented';
}

/// The server refused the key.
class SshAuthFailed extends SshConnectException {
  const SshAuthFailed(super.host, this.cause);
  final Object cause;

  @override
  String toString() => 'SshAuthFailed(${host.user}@${host.address}): $cause';
}

/// No connection: DNS, TCP, timeout, or the server closed it.
class SshNetworkException extends SshConnectException {
  const SshNetworkException(super.host, this.cause);
  final Object cause;

  @override
  String toString() =>
      'SshNetworkException(${host.address}:${host.port}): $cause';
}
