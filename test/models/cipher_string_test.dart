import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/models/cipher_string.dart';
import 'package:vault_approver/models/encryption_type.dart';

void main() {
  final iv = base64Encode(Uint8List(16));
  final ct = base64Encode(Uint8List(32));
  final mac = base64Encode(Uint8List(32));

  group('CipherString', () {
    group('parse', () {
      test('parses type 2 (AES-256-CBC-HMAC) correctly', () {
        final cs = CipherString.parse('2.$iv|$ct|$mac');
        expect(cs.encType, EncryptionType.aesCbc256_HmacSha256_B64);
        expect(cs.iv!.length, 16);
        expect(cs.ciphertext.length, 32);
        expect(cs.mac!.length, 32);
      });

      test('parses type 4 (RSA-OAEP-SHA1) correctly', () {
        final cs = CipherString.parse('4.${base64Encode(Uint8List(256))}');
        expect(cs.encType, EncryptionType.rsa2048_OaepSha1_B64);
        expect(cs.iv, isNull);
        expect(cs.ciphertext.length, 256);
        expect(cs.mac, isNull);
      });

      test('parses type 0 (AES-256-CBC no MAC) correctly', () {
        final cs = CipherString.parse('0.$iv|${base64Encode(Uint8List(48))}');
        expect(cs.encType, EncryptionType.aesCbc256_B64);
        expect(cs.iv!.length, 16);
        expect(cs.ciphertext.length, 48);
        expect(cs.mac, isNull);
      });

      test('type 2 without MAC is rejected (F15)', () {
        expect(
          () => CipherString.parse('2.$iv|$ct'),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => CipherString.parse('2.$iv|$ct|'),
          throwsA(isA<FormatException>()),
        );
      });

      test('bad IV length / extra parts are rejected', () {
        expect(
          () => CipherString.parse('2.${base64Encode(Uint8List(8))}|$ct|$mac'),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => CipherString.parse('2.$iv|$ct|$mac|$mac'),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws on missing type prefix', () {
        expect(
          () => CipherString.parse('noprefix'),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException on invalid type number', () {
        expect(
          () => CipherString.parse('99.abc'),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => CipherString.parse('x.abc'),
          throwsA(isA<FormatException>()),
        );
      });

      test('throws FormatException on bad base64', () {
        expect(
          () => CipherString.parse('2.$iv|@@@|$mac'),
          throwsA(isA<FormatException>()),
        );
      });
    });

    group('encode', () {
      test('roundtrips type 2 correctly', () {
        final cs = CipherString(
          encType: EncryptionType.aesCbc256_HmacSha256_B64,
          iv: Uint8List.fromList(List.generate(16, (i) => i)),
          ciphertext: Uint8List.fromList(List.generate(32, (i) => i + 100)),
          mac: Uint8List.fromList(List.generate(32, (i) => i + 200)),
        );
        final reparsed = CipherString.parse(cs.encode());
        expect(reparsed.encType, cs.encType);
        expect(reparsed.iv, cs.iv);
        expect(reparsed.ciphertext, cs.ciphertext);
        expect(reparsed.mac, cs.mac);
      });

      test('roundtrips type 4 correctly', () {
        final cs = CipherString(
          encType: EncryptionType.rsa2048_OaepSha1_B64,
          ciphertext: Uint8List.fromList(List.generate(256, (i) => i % 256)),
        );
        final encoded = cs.encode();
        expect(encoded.startsWith('4.'), isTrue);
        expect(CipherString.parse(encoded).ciphertext, cs.ciphertext);
      });
    });
  });
}
