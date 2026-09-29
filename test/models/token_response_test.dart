import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/models/api_error.dart';
import 'package:vault_approver/models/token_response.dart';

void main() {
  group('TokenResponse', () {
    test('Vaultwarden 1.37 password grant (Key + MasterPasswordUnlock)', () {
      final t = TokenResponse.fromJson({
        'access_token': 'at',
        'expires_in': 7200,
        'token_type': 'Bearer',
        'refresh_token': 'rt',
        'PrivateKey': '2.pk',
        'Kdf': 0,
        'KdfIterations': 600000,
        'KdfMemory': null,
        'KdfParallelism': null,
        'ResetMasterPassword': false,
        'ForcePasswordReset': false,
        'scope': 'api offline_access',
        'UserDecryptionOptions': {
          'HasMasterPassword': true,
          'MasterPasswordUnlock': {
            'Kdf': {
              'KdfType': 0,
              'Iterations': 600000,
              'Memory': null,
              'Parallelism': null,
            },
            'MasterKeyEncryptedUserKey': '2.mpu|key|mac',
            'MasterKeyWrappedUserKey': '2.mpu|key|mac',
            'Salt': 'user@example.com',
          },
          'Object': 'userDecryptionOptions',
        },
        'Key': '2.legacy|key|mac',
        'TwoFactorToken': 'remember-me',
      });
      expect(t.accessToken, 'at');
      expect(t.refreshToken, 'rt');
      expect(t.expiresIn, 7200);
      expect(t.protectedUserKey, '2.mpu|key|mac');
      expect(t.masterPasswordUnlock!.kdf!.iterations, 600000);
      expect(t.masterPasswordUnlock!.salt, 'user@example.com');
      expect(t.twoFactorToken, 'remember-me');
      expect(t.hasMasterPassword, isTrue);
      final now = DateTime.utc(2026);
      expect(t.expiryFrom(now), now.add(const Duration(hours: 2)));
    });

    test('camelCase keys (SDK style) are accepted too', () {
      final t = TokenResponse.fromJson({
        'access_token': 'at',
        'userDecryptionOptions': {
          'masterPasswordUnlock': {
            'kdf': {
              'kdfType': 1,
              'iterations': 3,
              'memory': 64,
              'parallelism': 4
            },
            'masterKeyEncryptedUserKey': '2.a|b|c',
            'salt': 's@example.com',
          },
        },
      });
      expect(t.protectedUserKey, '2.a|b|c');
      expect(t.masterPasswordUnlock!.kdf!.isArgon2id, isTrue);
      expect(t.expiresIn, 3600);
    });

    test('falls back to the deprecated Key', () {
      final t = TokenResponse.fromJson({
        'access_token': 'at',
        'Key': '2.legacy|key|mac',
        'UserDecryptionOptions': {
          'HasMasterPassword': true,
          'MasterPasswordUnlock': null
        },
      });
      expect(t.protectedUserKey, '2.legacy|key|mac');
      expect(t.requireProtectedUserKey(), '2.legacy|key|mac');
    });

    test('neither Key nor MasterPasswordUnlock → MissingUserKeyException (A8)',
        () {
      final t = TokenResponse.fromJson({
        'access_token': 'at',
        'refresh_token': 'rt',
        'UserDecryptionOptions': {'HasMasterPassword': false},
      });
      expect(t.protectedUserKey, isNull);
      expect(
        t.requireProtectedUserKey,
        throwsA(isA<MissingUserKeyException>()),
      );
    });

    test('refresh response (no keys) parses', () {
      final t = TokenResponse.fromJson({
        'refresh_token': 'rt2',
        'access_token': 'at2',
        'expires_in': '3600',
        'token_type': 'Bearer',
      });
      expect(t.accessToken, 'at2');
      expect(t.refreshToken, 'rt2');
      expect(t.expiresIn, 3600);
    });

    test('no access_token → FormatException', () {
      expect(
        () => TokenResponse.fromJson({'error': 'invalid_grant'}),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
