import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'host.dart';
import 'key_store.dart';
import 'known_hosts.dart';
import 'secret_store.dart';

/// Asks the user whether to trust [key], the first key seen for [host].
typedef TrustPrompt = Future<bool> Function(Host host, HostKey key);

/// Shows the user a [TailscaleCheck]. It must not wait for the user: the
/// login goes on while the check is open.
typedef TailscaleCheckPrompt = void Function(TailscaleCheck check);

/// Tailscale SSH in check mode holds the login of a [SshAuth.tailscale]
/// host until the user approves it at [url] in a browser.
class TailscaleCheck {
  TailscaleCheck(this.host, this.url, this.result, this._cancel);

  final Host host;
  final Uri url;

  /// Completes when the login ends: true if it went through.
  final Future<bool> result;

  final void Function() _cancel;

  /// Gives up the login; [SshConnector.open] throws
  /// [SshTailscaleCheckNeeded].
  void cancel() => _cancel();
}

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
    this.onTrusted,
    this.onTailscaleCheck,
    this.timeout = const Duration(seconds: 15),
    this.checkTimeout = const Duration(minutes: 3),
  });

  final KnownHosts knownHosts;
  final KeyStore keys;
  final TrustPrompt askTrust;

  /// Called when the user has trusted the key of a new host.
  final void Function(Host host)? onTrusted;

  /// Shows a Tailscale check to the user. Null where no one can see it,
  /// as in the watchers: a login that needs a check then fails at once.
  final TailscaleCheckPrompt? onTailscaleCheck;

  /// For each of TCP connect, handshake and login.
  final Duration timeout;

  /// For the login of a [SshAuth.tailscale] host, which may wait for the
  /// user to approve a check in a browser.
  final Duration checkTimeout;

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
    onTrusted?.call(host);
    return _connect(host, presented);
  }

  /// Connects only as far as the host key, then closes.
  Future<HostKey> _readHostKey(Host host) async {
    try {
      (await _client(host, const _Login(), null)).close(); // never logs in
    } on _HostKeySeen catch (e) {
      return e.key;
    }
    throw SshNetworkException(host, 'no host key');
  }

  /// Connects and logs in, if the server shows [expected].
  Future<SSHClient> _connect(Host host, HostKey expected) async {
    final _Login login;
    try {
      login = switch (host.auth) {
        SshAuth.key => _Login(identities: await keys.identities(host.keyId!)),
        SshAuth.password => _Login(
          password:
              await keys.password(host.id) ??
              (throw StateError('no saved password')),
        ),
        // Only the "none" method: Tailscale SSH needs nothing more.
        SshAuth.tailscale => const _Login(),
      };
    } on SecretStoreException catch (e) {
      throw SshSecretsUnreadable(host, e);
    } catch (e) {
      // The saved key or password is gone or does not parse.
      throw SshAuthFailed(host, e);
    }
    return _client(host, login, expected);
  }

  /// Accepts only the host key [expected]. With [expected] null it rejects
  /// every key and throws [_HostKeySeen] with the key the server showed.
  Future<SSHClient> _client(Host host, _Login login, HostKey? expected) async {
    final Socket socket;
    try {
      socket = await Socket.connect(host.address, host.port, timeout: timeout);
    } catch (e) {
      throw SshNetworkException(host, e);
    }
    HostKey? seen;
    final password = login.password;
    // dartssh2 tries each method once, and the password method first, even
    // on a server that does not offer it; so it cannot tell whether that
    // try was checked. A wrong password costs at most two failed logins:
    // one per method. Keyboard-interactive gets it in one round only.
    var prompted = false;
    String? promptPassword() {
      if (prompted) return null;
      prompted = true;
      return password;
    }

    // Only on a logging-in connection: the first-use read never gets as
    // far as the login.
    final tailscale = host.auth == SshAuth.tailscale && expected != null;
    Uri? checkUrl;
    late final SSHClient client;
    void onBanner(String banner) {
      if (checkUrl != null) return; // one check per login
      final url = tailscaleCheckUrl(banner);
      if (url == null) return;
      checkUrl = url;
      if (onTailscaleCheck case final prompt?) {
        final result = client.authenticated.then(
          (_) => true,
          onError: (Object _) => false,
        );
        prompt(TailscaleCheck(host, url, result, client.close));
      } else {
        client.close(); // no one to approve it
      }
    }

    client = SSHClient(
      _NativeSocket(socket),
      username: host.user,
      identities: login.identities,
      onPasswordRequest: password == null ? null : () => password,
      onUserInfoRequest: password == null
          ? null
          : (request) => answerPasswordPrompt(request, promptPassword),
      // dartssh2 gives the fingerprint as the text "SHA256:<base64>".
      onVerifyHostKey: (type, fp) {
        seen = HostKey.signedWith(type, utf8.decode(fp));
        return seen == expected;
      },
      algorithms: SSHAlgorithms(hostkey: hostKeyOrder(expected?.type)),
      onUserauthBanner: tailscale ? onBanner : null,
      handshakeTimeout: timeout,
      authTimeout: tailscale ? checkTimeout : timeout,
    );
    _peers[client] = socket.remoteAddress;
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
      // Cancelled, timed out, or no one to ask.
      if (checkUrl case final url?) throw SshTailscaleCheckNeeded(host, url);
      throw SshNetworkException(host, e);
    }
  }
}

/// The host key algorithms that dartssh2 offers, those of key type
/// [trusted] first. A server with more than one host key then shows the
/// trusted one, not the one dartssh2 likes best. With no trusted key, the
/// default order.
List<SSHHostkeyType> hostKeyOrder(String? trusted) {
  final all = const SSHAlgorithms().hostkey;
  if (trusted == null) return all;
  bool isTrusted(SSHHostkeyType t) => HostKey.keyTypeOf(t.name) == trusted;
  return [...all.where(isTrusted), ...all.where((t) => !isTrusted(t))];
}

/// The address that the connection of [client] went to, when an
/// [SshConnector] made it. A name can resolve to more than one address;
/// this is the one that answered.
InternetAddress? sshPeerAddress(SSHClient client) => _peers[client];

final _peers = Expando<InternetAddress>();

/// dartssh2's own socket, which does not tell its peer address.
class _NativeSocket implements SSHSocket {
  _NativeSocket(this._socket);

  final Socket _socket;

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() => _socket.close();

  @override
  void destroy() => _socket.destroy();

  @override
  Future<void> flush() => _socket.flush();
}

/// What [SshConnector] logs in with: a key or a password.
class _Login {
  const _Login({this.identities = const [], this.password});
  final List<SSHKeyPair> identities;
  final String? password;
}

/// Answers a keyboard-interactive round. A round with no prompts gets an
/// empty answer; one hidden prompt, the "Password:" of PAM, gets
/// [password], which gives it only once. Anything else, such as a
/// second-factor code after the password, gets null: the method gives up.
List<String>? answerPasswordPrompt(
  SSHUserInfoRequest request,
  String? Function() password,
) => switch (request.prompts) {
  [] => const [],
  [SSHUserInfoPrompt(echo: false)] => switch (password()) {
    final p? => [p],
    null => null,
  },
  _ => null,
};

/// The link in the login banner of a Tailscale SSH check, such as
/// "# To authenticate, visit: https://login.tailscale.com/a/...". Null
/// when the banner has no https link.
Uri? tailscaleCheckUrl(String banner) {
  final match = RegExp(r'https://\S+').firstMatch(banner);
  final url = match == null ? null : Uri.tryParse(match[0]!);
  return url != null && url.host.isNotEmpty ? url : null;
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

/// The server refused the key or the password.
class SshAuthFailed extends SshConnectException {
  const SshAuthFailed(super.host, this.cause);
  final Object cause;

  @override
  String toString() => 'SshAuthFailed(${host.user}@${host.address}): $cause';
}

/// The platform keystore could not read the saved key or password. Nothing
/// was deleted: a later try, as after unlocking the phone, may read it.
class SshSecretsUnreadable extends SshConnectException {
  const SshSecretsUnreadable(super.host, this.cause);
  final SecretStoreException cause;

  @override
  String toString() => 'SshSecretsUnreadable(${host.address}): $cause';
}

/// Tailscale SSH holds the login for a check at [url] that no one
/// approved: no one was there to ask, the user cancelled, or the time ran
/// out.
class SshTailscaleCheckNeeded extends SshConnectException {
  const SshTailscaleCheckNeeded(super.host, this.url);
  final Uri url;

  @override
  String toString() => 'SshTailscaleCheckNeeded(${host.address}): $url';
}

/// No connection: DNS, TCP, timeout, or the server closed it.
class SshNetworkException extends SshConnectException {
  const SshNetworkException(super.host, this.cause);
  final Object cause;

  @override
  String toString() =>
      'SshNetworkException(${host.address}:${host.port}): $cause';
}
