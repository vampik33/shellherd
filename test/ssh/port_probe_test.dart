import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/ssh/port_probe.dart';

void main() {
  group('sshPortOpen', () {
    test('a port that takes the connection is open', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final accepted = server.first;
      expect(await sshPortOpen('127.0.0.1', server.port), isTrue);
      // The probe closes its side at once.
      final socket = await accepted;
      expect(await socket.isEmpty, isTrue);
      socket.destroy();
    });

    test('a closed port is not', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      expect(await sshPortOpen('127.0.0.1', port), isFalse);
    });

    test('a name that does not resolve is not', () async {
      // .invalid never resolves (RFC 6761).
      expect(await sshPortOpen('no-such-host.invalid', 22), isFalse);
    });
  });
}
