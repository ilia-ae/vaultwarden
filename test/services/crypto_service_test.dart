import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:vault_approver/models/api_error.dart';
import 'package:vault_approver/models/cipher_string.dart';
import 'package:vault_approver/models/encryption_type.dart';
import 'package:vault_approver/models/kdf_params.dart';
import 'package:vault_approver/services/crypto_service.dart';
import 'package:vault_approver/utils/eff_wordlist.dart';

import 'rsa_fixture.dart';

/// SDK vector: sdk-internal crates/bitwarden-core/src/auth/auth_request.rs.
const _sdkPublicKey =
    'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvyLRDUwXB4BfQ507D4meFPmwn5zwy3IqTPJO4plrrhnclWahXa240BzyFW9gHgYu+Jrgms5xBfRTBMcEsqqNm7+JpB6C1B6yvnik0DpJgWQw1rwvy4SUYidpR/AWbQi47n/hvnmzI/sQxGddVfvWu1iTKOlf5blbKYAXnUE5DZBGnrWfacNXwRRdtP06tFB0LwDgw+91CeLSJ9py6dm1qX5JIxoO8StJOQl65goLCdrTWlox+0Jh4xFUfCkb+s3px+OhSCzJbvG/hlrSRcUz5GnwlCEyF3v5lfUtV96MJD+78d8pmH6CfFAp2wxKRAbGdk+JccJYO6y6oIXd3Fm7twIDAQAB';

const _pbkdf2Min = KdfParams(kdfType: 0, iterations: 5000);

Uint8List _bytes(List<int> v) => Uint8List.fromList(v);

void main() {
  late CryptoService crypto;

  setUp(() {
    crypto = CryptoService();
  });

  group('fingerprint phrase (F3)', () {
    test('matches the SDK known-answer vector', () {
      expect(
        crypto.generateFingerprintPhrase(_sdkPublicKey, 'test@bitwarden.com'),
        'childless-unfair-prowler-dropbox-designate',
      );
    });

    test('uses the EFF wordlist by default and an explicit list the same', () {
      expect(
        crypto.generateFingerprintPhrase(
          _sdkPublicKey,
          'test@bitwarden.com',
          effWordlist,
        ),
        'childless-unfair-prowler-dropbox-designate',
      );
      expect(effWordlist, hasLength(7776));
    });

    test('email is trimmed and lower-cased', () {
      expect(
        crypto.generateFingerprintPhrase(
            _sdkPublicKey, '  TEST@Bitwarden.COM '),
        'childless-unfair-prowler-dropbox-designate',
      );
    });

    test('different email → different phrase', () {
      expect(
        crypto.generateFingerprintPhrase(_sdkPublicKey, 'other@bitwarden.com'),
        isNot('childless-unfair-prowler-dropbox-designate'),
      );
    });

    test('different public keys produce different phrases', () {
      final a = crypto.generateFingerprintPhrase(_sdkPublicKey, 'a@b.com');
      final b = crypto.generateFingerprintPhrase(fixtureRsaSpkiB64, 'a@b.com');
      expect(a, isNot(equals(b)));
      expect(a.split('-'), hasLength(5));
    });

    test('malformed public key → FormatException / null (A1)', () {
      for (final bad in [
        'not base64!!',
        base64Encode(Uint8List(128)),
        base64Encode(utf8.encode('hello')),
        '',
      ]) {
        expect(
          () => crypto.generateFingerprintPhrase(bad, 'a@b.com'),
          throwsA(isA<FormatException>()),
          reason: bad,
        );
        expect(crypto.tryGenerateFingerprintPhrase(bad, 'a@b.com'), isNull);
      }
      expect(
        crypto.tryGenerateFingerprintPhrase(
            _sdkPublicKey, 'test@bitwarden.com'),
        'childless-unfair-prowler-dropbox-designate',
      );
    });
  });

  group('master key KATs (F4)', () {
    test('PBKDF2 SDK vector (100000 iterations)', () async {
      // sdk-internal master_key.rs test_password_hash_pbkdf2: the salt is
      // trimmed and lower-cased, so all three spellings give the same hash.
      const kdf = KdfParams(kdfType: 0, iterations: 100000);
      for (final salt in [
        'test@bitwarden.com',
        'TEST@bitwarden.com',
        ' test@bitwarden.com',
      ]) {
        final mk = await crypto.deriveMasterKey(salt, 'asdfasdf', kdf);
        final hash = await crypto.deriveMasterPasswordHash(mk, 'asdfasdf');
        expect(
          base64Encode(hash),
          'wmyadRMyBZOH7P/a/ucTCbSghKgdzDpPqUnu/DAVtSw=',
          reason: salt,
        );
      }
    });

    test('Argon2id SDK vector (4 it, 32 MiB, p=2, full SHA-256 salt)',
        () async {
      const kdf = KdfParams(
        kdfType: 1,
        iterations: 4,
        memory: 32, // MiB, as the server sends it
        parallelism: 2,
      );
      final mk = await crypto.deriveMasterKey('test_salt', 'asdfasdf', kdf);
      final hash = await crypto.deriveMasterPasswordHash(mk, 'asdfasdf');
      expect(
          base64Encode(hash), 'PR6UjYmjmppTYcdyTiNbAhPJuQQOmynKbdEl1oyi/iQ=');
    });

    test('isolate and in-process derivation agree', () async {
      final inline = CryptoService(runKdfInIsolate: false);
      final a =
          await crypto.deriveMasterKey('user@test.com', 'pass', _pbkdf2Min);
      final b =
          await inline.deriveMasterKey('user@test.com', 'pass', _pbkdf2Min);
      expect(a, hasLength(32));
      expect(a, equals(b));
    });

    test('server salt (F14) is used instead of the email, trimmed + lowered',
        () async {
      const withSalt = KdfParams(
        kdfType: 0,
        iterations: 100000,
        salt: ' Test@Bitwarden.com ',
      );
      final mk = await crypto.deriveMasterKey(
        'changed@example.com',
        'asdfasdf',
        withSalt,
      );
      final hash = await crypto.deriveMasterPasswordHash(mk, 'asdfasdf');
      expect(
        base64Encode(hash),
        'wmyadRMyBZOH7P/a/ucTCbSghKgdzDpPqUnu/DAVtSw=',
      );
    });

    test('deriveLoginKeys bundles key, stretch and hash', () async {
      final keys = await crypto.deriveLoginKeys(
        'test@bitwarden.com',
        'asdfasdf',
        const KdfParams(kdfType: 0, iterations: 100000),
      );
      expect(keys.masterKey, hasLength(32));
      expect(keys.stretchedMasterKey, hasLength(64));
      expect(
        keys.masterPasswordHashB64,
        'wmyadRMyBZOH7P/a/ucTCbSghKgdzDpPqUnu/DAVtSw=',
      );
      keys.wipe();
      expect(keys.masterKey.every((b) => b == 0), isTrue);
    });

    test('different passwords produce different keys', () async {
      final k1 =
          await crypto.deriveMasterKey('test@example.com', 'p1', _pbkdf2Min);
      final k2 =
          await crypto.deriveMasterKey('test@example.com', 'p2', _pbkdf2Min);
      expect(k1, isNot(equals(k2)));
    });
  });

  group('KDF minimums (F15)', () {
    const weak = <KdfParams>[
      KdfParams(kdfType: 0, iterations: 1),
      KdfParams(kdfType: 0, iterations: 4999),
      KdfParams(kdfType: 1, iterations: 3, memory: 15, parallelism: 4),
      KdfParams(kdfType: 1, iterations: 1, memory: 64, parallelism: 4),
      KdfParams(kdfType: 1, iterations: 3, memory: 64, parallelism: 0),
      KdfParams(kdfType: 1, iterations: 3, memory: 4096, parallelism: 4),
      KdfParams(kdfType: 1, iterations: 3),
    ];
    for (final kdf in weak) {
      test('rejects $kdf', () async {
        await expectLater(
          crypto.deriveMasterKey('a@b.com', 'pw', kdf),
          throwsA(isA<KdfTooWeakException>()),
        );
      });
    }

    test('rejects unknown KDF types', () async {
      await expectLater(
        crypto.deriveMasterKey(
          'a@b.com',
          'pw',
          const KdfParams(kdfType: 7, iterations: 600000),
        ),
        throwsA(isA<UnsupportedKdfException>()),
      );
    });

    test('accepts the documented minimums', () {
      _pbkdf2Min.validate();
      const KdfParams(kdfType: 1, iterations: 2, memory: 16, parallelism: 1)
          .validate();
    });
  });

  group('stretchMasterKey', () {
    test('produces 64 bytes, deterministic, enc != mac', () {
      final masterKey = _bytes(List.generate(32, (i) => i));
      final s1 = crypto.stretchMasterKey(masterKey);
      final s2 = crypto.stretchMasterKey(masterKey);
      expect(s1, hasLength(64));
      expect(s1, equals(s2));
      expect(s1.sublist(0, 32), isNot(equals(s1.sublist(32))));
    });
  });

  group('deriveMasterPasswordHash', () {
    test('produces 32 deterministic bytes', () async {
      final masterKey = _bytes(List.generate(32, (i) => i));
      final h1 = await crypto.deriveMasterPasswordHash(masterKey, 'password');
      final h2 = await crypto.deriveMasterPasswordHash(masterKey, 'password');
      expect(h1, hasLength(32));
      expect(h1, equals(h2));
    });
  });

  group('symmetric encryption', () {
    test('roundtrips data correctly', () {
      final key = _bytes(List.generate(64, (i) => i));
      final plaintext = _bytes(utf8.encode('Hello, Bitwarden!'));
      final encrypted = crypto.encryptSymmetric(plaintext, key);
      expect(encrypted.encType, EncryptionType.aesCbc256_HmacSha256_B64);
      expect(encrypted.iv, hasLength(16));
      expect(encrypted.mac, hasLength(32));
      expect(crypto.decryptSymmetric(encrypted, key), equals(plaintext));
    });

    test('random IV → different ciphertexts', () {
      final key = _bytes(List.generate(64, (i) => i));
      final enc1 = crypto.encryptSymmetric(_bytes([1, 2, 3]), key);
      final enc2 = crypto.encryptSymmetric(_bytes([1, 2, 3]), key);
      expect(enc1.iv, isNot(equals(enc2.iv)));
      expect(enc1.ciphertext, isNot(equals(enc2.ciphertext)));
    });

    test('fails on tampered MAC', () {
      final key = _bytes(List.generate(64, (i) => i));
      final encrypted = crypto.encryptSymmetric(_bytes([1, 2, 3]), key);
      final tamperedMac = Uint8List.fromList(encrypted.mac!)..[0] ^= 0xFF;
      final tampered = CipherString(
        encType: encrypted.encType,
        iv: encrypted.iv,
        ciphertext: encrypted.ciphertext,
        mac: tamperedMac,
      );
      expect(
        () => crypto.decryptSymmetric(tampered, key),
        throwsA(isA<StateError>()),
      );
    });

    test('fails on wrong key', () {
      final key1 = _bytes(List.generate(64, (i) => i));
      final key2 = _bytes(List.generate(64, (i) => i + 1));
      final encrypted = crypto.encryptSymmetric(_bytes([1, 2, 3]), key1);
      expect(
        () => crypto.decryptSymmetric(encrypted, key2),
        throwsA(isA<StateError>()),
      );
    });

    test('a type-2 value without MAC is rejected (F15)', () {
      final key = _bytes(List.generate(64, (i) => i));
      final encrypted = crypto.encryptSymmetric(_bytes([1, 2, 3]), key);
      final noMac = CipherString(
        encType: encrypted.encType,
        iv: encrypted.iv,
        ciphertext: encrypted.ciphertext,
      );
      expect(
        () => crypto.decryptSymmetric(noMac, key),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => crypto.decryptUserKey(noMac, key),
        throwsA(isA<FormatException>()),
      );
    });

    test('encrypt → encode → parse → decrypt roundtrip', () {
      final key = _bytes(List.generate(64, (i) => (i * 3 + 7) % 256));
      final encrypted =
          crypto.encryptSymmetric(_bytes(utf8.encode('vault data')), key);
      final encoded = encrypted.encode();
      expect(encoded, startsWith('2.'));
      final decrypted =
          crypto.decryptSymmetric(CipherString.parse(encoded), key);
      expect(utf8.decode(decrypted), 'vault data');
    });
  });

  group('user key decryption', () {
    test('type 2 with the stretched master key', () {
      final userKey = _bytes(List.generate(64, (i) => (i * 7 + 3) % 256));
      final stretched = _bytes(List.generate(64, (i) => i));
      final protectedKey = crypto.encryptSymmetric(userKey, stretched);
      expect(crypto.decryptUserKey(protectedKey, stretched), equals(userKey));
    });

    test('rejects non-type-2 cipher strings', () {
      final cs = CipherString(
        encType: EncryptionType.rsa2048_OaepSha1_B64,
        ciphertext: Uint8List(256),
      );
      expect(
        () => crypto.decryptUserKey(cs, Uint8List(64)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('decryptUserKeyWithMasterKey handles type 2', () {
      final masterKey = _bytes(List.generate(32, (i) => i * 5 % 256));
      final userKey = _bytes(List.generate(64, (i) => (i * 13) % 256));
      final protectedKey = crypto.encryptSymmetric(
        userKey,
        crypto.stretchMasterKey(masterKey),
      );
      expect(
        crypto.decryptUserKeyWithMasterKey(protectedKey, masterKey),
        equals(userKey),
      );
    });

    test('type 0 (legacy) SDK vector, raw master key (F17)', () {
      // sdk-internal master_key.rs test_decrypt_cbc256.
      final masterKey =
          base64Decode('hvBMMb1t79YssFZkpetYsM3deyVuQv4r88Uj9gvYe08=');
      final cs = CipherString.parse(
        '0.tn/heK4HLbbEe+yEkC+kvw==|8QM94f7aVTtjm/bmvRdVxOxiLiiZtHYYO7+oBdjFCkilncesx0iVrXPl+tMKqW+Jo7+FtZdPNsTrL6RdoG7i5QbCRVwK+9010+xm7MTQY8s=',
      );
      final userKey = crypto.decryptUserKeyWithMasterKey(cs, masterKey);
      expect(userKey.sublist(0, 32), [
        116, 170, 187, 43, 80, 212, 193, 202, 234, 181, 57, 66, 151, 249, 59, //
        47, 70, 16, 57, 4, 170, 78, 85, 241, 152, 232, 91, 57, 9, 87, 209, 245,
      ]);
      expect(userKey.sublist(32, 64), [
        40, 245, 106, 140, 2, 225, 138, 213, 98, 223, 92, 168, 135, 208, 22, //
        194, 31, 21, 178, 252, 203, 198, 35, 174, 53, 218, 254, 151, 235, 57,
        7, 98,
      ]);
    });

    test('type 0 (legacy) SDK vector via PBKDF2 600000 (full chain)', () async {
      // sdk-internal master_key.rs test_decrypt_user_key_aes_cbc256_b64.
      final masterKey = await crypto.deriveMasterKey(
        'legacy@bitwarden.com',
        'asdfasdfasdf',
        const KdfParams(kdfType: 0, iterations: 600000),
      );
      final cs = CipherString.parse(
        '0.8UClLa8IPE1iZT7chy5wzQ==|6PVfHnVk5S3XqEtQemnM5yb4JodxmPkkWzmDRdfyHtjORmvxqlLX40tBJZ+CKxQWmS8tpEB5w39rbgHg/gqs0haGdZG4cPbywsgGzxZ7uNI=',
      );
      final userKey = crypto.decryptUserKeyWithMasterKey(cs, masterKey);
      expect(userKey.sublist(0, 32), [
        12, 95, 151, 203, 37, 4, 236, 67, 137, 97, 90, 58, 6, 127, 242, 28, //
        209, 168, 125, 29, 118, 24, 213, 44, 117, 202, 2, 115, 132, 165, 125,
        148,
      ]);
    });

    test('type 0 with a wrong key fails like a MAC error', () {
      final cs = CipherString.parse(
        '0.tn/heK4HLbbEe+yEkC+kvw==|8QM94f7aVTtjm/bmvRdVxOxiLiiZtHYYO7+oBdjFCkilncesx0iVrXPl+tMKqW+Jo7+FtZdPNsTrL6RdoG7i5QbCRVwK+9010+xm7MTQY8s=',
      );
      expect(
        () => crypto.decryptUserKeyWithMasterKey(cs, Uint8List(32)),
        throwsA(anyOf(isA<StateError>(), isA<ArgumentError>())),
      );
    });
  });

  group('approval payload (compatible_ok, unchanged)', () {
    test("'4.' + RSA-OAEP-SHA1 of the raw user key bytes", () {
      final userKey = _bytes(List.generate(64, (i) => (i * 11) % 256));
      final encrypted =
          crypto.encryptUserKeyForApproval(userKey, fixtureRsaSpkiB64);
      expect(encrypted, startsWith('4.'));
      final cs = CipherString.parse(encrypted);
      expect(cs.encType, EncryptionType.rsa2048_OaepSha1_B64);
      expect(cs.ciphertext, hasLength(256));

      final privateKey = RSAPrivateKey(
        BigInt.parse(fixtureRsaModulusHex, radix: 16),
        BigInt.parse(fixtureRsaPrivateExponentHex, radix: 16),
        BigInt.parse(fixtureRsaPrime1Hex, radix: 16),
        BigInt.parse(fixtureRsaPrime2Hex, radix: 16),
      );
      final decryptor = OAEPEncoding.withSHA1(RSAEngine())
        ..init(false, PrivateKeyParameter<RSAPrivateKey>(privateKey));
      expect(decryptor.process(cs.ciphertext), equals(userKey));
    });

    test('passes user keys of any length through (V2 COSE keys)', () {
      final longKey = _bytes(List.generate(150, (i) => i));
      final encrypted =
          crypto.encryptUserKeyForApproval(longKey, fixtureRsaSpkiB64);
      expect(encrypted, startsWith('4.'));
    });
  });
}
