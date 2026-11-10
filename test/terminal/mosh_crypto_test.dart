/// Checks the AES-OCB of dart_mosh against RFC 7253 (AES-128, 96-bit nonce,
/// 128-bit tag, as mosh uses it), so that a change in the package cannot
/// slip through.
library;

import 'dart:typed_data';

import 'package:dart_mosh/dart_mosh.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shellherd/terminal/mosh_shell_session.dart';

Uint8List _hex(String s) => Uint8List.fromList([
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
]);

Uint8List _bytes(int n) => Uint8List.fromList(List.generate(n, (i) => i));

void main() {
  final key = _hex('000102030405060708090a0b0c0d0e0f');

  // RFC 7253 appendix A, as OpenSSL's AES-OCB computes them:
  // (nonce, associated data length, plaintext length, ciphertext).
  final vectors = [
    ('bbaa99887766554433221100', 0, 0, '785407bfffc8ad9edcc5520ac9111ee6'),
    (
      'bbaa99887766554433221101',
      8,
      8,
      '6820b3657b6f615a5725bda0d3b4eb3a257c9af1f8f03009',
    ),
    ('bbaa99887766554433221102', 8, 0, '81017f8203f081277152fade694a0a00'),
    (
      'bbaa99887766554433221103',
      0,
      8,
      '45dd69f8f5aae72414054cd1f35d82760b2cd00d2f99bfa9',
    ),
    (
      'bbaa99887766554433221104',
      16,
      16,
      '571d535b60b277188be5147170a9a22c3ad7a4ff3835b8c5701c1ccec8fc3358',
    ),
    (
      'bbaa99887766554433221107',
      24,
      24,
      '1ca2207308c87c010756104d8840ce1952f09673a448a122c92c62241051f573'
          '56d7f3c90bb0e07f',
    ),
    (
      'bbaa9988776655443322110f',
      40,
      40,
      '4412923493c57d5de0d700f753cce0d1d2d95060122e9f15a5ddbfc5787e50b5'
          'cc55ee507bcb084e240a353649432ac6c1bda9acba93f56d',
    ),
  ];

  for (final (nonce, adLength, ptLength, expected) in vectors) {
    test('RFC 7253 nonce $nonce', () {
      final ocb = AesOcb(key, associatedData: _bytes(adLength));
      final sealed = ocb.seal(nonce: _hex(nonce), plaintext: _bytes(ptLength));
      expect(sealed, _hex(expected));
      expect(
        ocb.open(nonce: _hex(nonce), ciphertextWithTag: sealed),
        _bytes(ptLength),
      );
    });
  }

  test('a changed byte fails the tag', () {
    final ocb = AesOcb(key);
    final nonce = _hex('bbaa99887766554433221103');
    final sealed = ocb.seal(nonce: nonce, plaintext: _bytes(8));
    sealed[0] ^= 1;
    expect(
      () => ocb.open(nonce: nonce, ciphertextWithTag: sealed),
      throwsA(isA<MoshException>()),
    );
  });

  group('ServerOnlyCipher', () {
    final moshKey = MoshKey(key);
    var packets = 0;
    final cipher = ServerOnlyCipher(
      MoshPacketCipher.aesOcb(moshKey),
      onPacket: () => packets++,
    );
    final plain = Uint8List.fromList([1, 2, 3]);

    test('takes a packet of the server, whose nonce has the high bit', () {
      packets = 0;
      // The server's direction bit is the top bit of the 8-byte nonce.
      final wire = Uint8List.fromList([0x80, 0, 0, 0, 0, 0, 0, 5]);
      final fromServer = Uint8List.fromList([
        ...wire,
        ...AesOcb(key).seal(
          nonce: Uint8List.fromList([0, 0, 0, 0, ...wire]),
          plaintext: plain,
        ),
      ]);
      expect(cipher.decrypt(fromServer), plain);
      expect(packets, 1);
    });

    test('drops a packet of the app sent back to it', () {
      packets = 0;
      final own = cipher.encrypt(nonce: 5, plaintext: plain);
      expect(() => cipher.decrypt(own), throwsA(isA<MoshException>()));
      expect(packets, 0);
    });
  });
}
