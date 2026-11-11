import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/ssh/json_file.dart';
import 'package:shellherd/ssh/known_hosts.dart';
import 'package:shellherd/ssh/ssh_connector.dart';
import 'package:shellherd/ui/host_key_dialog.dart';

void main() {
  test('an RSA key is one key type, whichever algorithm signed', () {
    const fp = 'SHA256:abc';
    expect(HostKey.signedWith('rsa-sha2-512', fp), const HostKey('ssh-rsa', fp));
    expect(HostKey.signedWith('rsa-sha2-256', fp), const HostKey('ssh-rsa', fp));
    expect(HostKey.signedWith('ssh-rsa', fp), const HostKey('ssh-rsa', fp));
    expect(
      HostKey.signedWith('ssh-ed25519', fp),
      const HostKey('ssh-ed25519', fp),
    );
  });

  test('an entry saved with an RSA algorithm reads as ssh-rsa', () async {
    final dir = await Directory.systemTemp.createTemp('shellherd-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/known_hosts.json');
    await file.writeAsString(
      jsonEncode({
        'h:22': {'type': 'rsa-sha2-256', 'fingerprint': 'SHA256:abc'},
      }),
    );
    expect(
      await KnownHosts(JsonFile(file)).lookup('h', 22),
      const HostKey('ssh-rsa', 'SHA256:abc'),
    );
  });

  test('the trusted key type goes first, the rest keep their order', () {
    expect(hostKeyOrder('ssh-rsa'), [
      SSHHostkeyType.rsaSha512,
      SSHHostkeyType.rsaSha256,
      SSHHostkeyType.ed25519,
      SSHHostkeyType.ecdsa521,
      SSHHostkeyType.ecdsa384,
      SSHHostkeyType.ecdsa256,
    ]);
    expect(hostKeyOrder('ecdsa-sha2-nistp384'), [
      SSHHostkeyType.ecdsa384,
      SSHHostkeyType.ed25519,
      SSHHostkeyType.rsaSha512,
      SSHHostkeyType.rsaSha256,
      SSHHostkeyType.ecdsa521,
      SSHHostkeyType.ecdsa256,
    ]);
    expect(hostKeyOrder('ssh-ed25519'), const SSHAlgorithms().hostkey);
    expect(hostKeyOrder(null), const SSHAlgorithms().hostkey);
  });

  test('the dialog names the host key file of the key type', () {
    expect(hostKeyFile('ssh-ed25519'), '/etc/ssh/ssh_host_ed25519_key.pub');
    expect(hostKeyFile('ssh-rsa'), '/etc/ssh/ssh_host_rsa_key.pub');
    expect(
      hostKeyFile('ecdsa-sha2-nistp256'),
      '/etc/ssh/ssh_host_ecdsa_key.pub',
    );
  });
}
