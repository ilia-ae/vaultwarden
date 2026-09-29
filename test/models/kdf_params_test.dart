import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/models/api_error.dart';
import 'package:vault_approver/models/kdf_params.dart';

void main() {
  group('KdfParams.fromJson (prelogin)', () {
    test('Vaultwarden 1.37 shape: kdfSettings preferred, salt null', () {
      final kdf = KdfParams.fromJson({
        'kdf': 0,
        'kdfIterations': 600000,
        'kdfMemory': null,
        'kdfParallelism': null,
        'kdfSettings': {
          'iterations': 600000,
          'kdfType': 0,
          'memory': null,
          'parallelism': null,
        },
        'salt': null,
      });
      expect(kdf.isPbkdf2, isTrue);
      expect(kdf.iterations, 600000);
      expect(kdf.salt, isNull);
      expect(kdf.saltFor(' User@Example.COM '), 'user@example.com');
    });

    test('Bitwarden PascalCase shape with Argon2id and server salt (F14)', () {
      final kdf = KdfParams.fromJson({
        'Kdf': 1,
        'KdfIterations': 3,
        'KdfMemory': 64,
        'KdfParallelism': 4,
        'KdfSettings': {
          'KdfType': 1,
          'Iterations': 3,
          'Memory': 64,
          'Parallelism': 4,
        },
        'Salt': 'Old@Example.com',
      });
      expect(kdf.isArgon2id, isTrue);
      expect(kdf.memory, 64); // MiB
      expect(kdf.parallelism, 4);
      expect(kdf.salt, 'Old@Example.com');
      expect(kdf.saltFor('new@example.com'), 'old@example.com');
    });

    test('kdfSettings wins over the deprecated flat fields', () {
      final kdf = KdfParams.fromJson({
        'kdf': 0,
        'kdfIterations': 100000,
        'kdfSettings': {
          'kdfType': 1,
          'iterations': 3,
          'memory': 64,
          'parallelism': 4
        },
      });
      expect(kdf.isArgon2id, isTrue);
    });

    test('falls back to the flat fields (older servers)', () {
      final kdf = KdfParams.fromJson({'kdf': 0, 'kdfIterations': 100000});
      expect(kdf.isPbkdf2, isTrue);
      expect(kdf.iterations, 100000);
    });

    test('empty salt means "use the email"', () {
      final kdf = KdfParams.fromJson(
        {'kdf': 0, 'kdfIterations': 100000, 'salt': '  '},
      );
      expect(kdf.salt, isNull);
    });

    test('unusable response → FormatException', () {
      expect(
        () => KdfParams.fromJson({'foo': 1}),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('MasterPasswordUnlock (F17)', () {
    test('parses Kdf + Salt case-insensitively', () {
      final kdf = KdfParams.tryFromMasterPasswordUnlock({
        'Kdf': {'KdfType': 1, 'Iterations': 3, 'Memory': 64, 'Parallelism': 4},
        'MasterKeyEncryptedUserKey': '2.x|y|z',
        'Salt': 'user@example.com',
      })!;
      expect(kdf.isArgon2id, isTrue);
      expect(kdf.salt, 'user@example.com');
      final camel = KdfParams.tryFromMasterPasswordUnlock({
        'kdf': {'kdfType': 0, 'iterations': 600000},
        'salt': 'user@example.com',
      })!;
      expect(camel.isPbkdf2, isTrue);
      expect(camel.iterations, 600000);
    });

    test('null/malformed → null', () {
      expect(KdfParams.tryFromMasterPasswordUnlock(null), isNull);
      expect(KdfParams.tryFromMasterPasswordUnlock({'Kdf': 'x'}), isNull);
    });
  });

  group('validate (F15)', () {
    test('minimums and maxima', () {
      expect(
        () => const KdfParams(kdfType: 0, iterations: 4999).validate(),
        throwsA(isA<KdfTooWeakException>()),
      );
      const KdfParams(kdfType: 0, iterations: 5000).validate();
      expect(
        () => const KdfParams(
                kdfType: 1, iterations: 2, memory: 15, parallelism: 1)
            .validate(),
        throwsA(isA<KdfTooWeakException>()),
      );
      expect(
        () => const KdfParams(
                kdfType: 1, iterations: 2, memory: 2048, parallelism: 1)
            .validate(),
        throwsA(isA<KdfTooWeakException>()),
      );
      expect(
        () => const KdfParams(
                kdfType: 1, iterations: 2, memory: 16, parallelism: 17)
            .validate(),
        throwsA(isA<KdfTooWeakException>()),
      );
      expect(
        () => const KdfParams(kdfType: 2, iterations: 1).validate(),
        throwsA(isA<UnsupportedKdfException>()),
      );
    });

    test(
        'iteration maxima = official ranges (a hostile server cannot pin '
        'the KDF for hours)', () {
      const KdfParams(kdfType: 0, iterations: 2000000).validate();
      const KdfParams(kdfType: 1, iterations: 10, memory: 1024, parallelism: 16)
          .validate();
      for (final bad in const [
        KdfParams(kdfType: 0, iterations: 2000001),
        KdfParams(kdfType: 0, iterations: 2147483647),
        KdfParams(kdfType: 1, iterations: 11, memory: 64, parallelism: 4),
        KdfParams(
            kdfType: 1, iterations: 2147483647, memory: 64, parallelism: 4),
      ]) {
        expect(bad.validate, throwsA(isA<KdfTooWeakException>()),
            reason: '$bad');
      }
    });

    test('sameKdfAs ignores salt', () {
      const a = KdfParams(kdfType: 0, iterations: 600000, salt: 'a');
      const b = KdfParams(kdfType: 0, iterations: 600000, salt: 'b');
      expect(a.sameKdfAs(b), isTrue);
      expect(
          a.sameKdfAs(const KdfParams(kdfType: 0, iterations: 5000)), isFalse);
    });
  });
}
