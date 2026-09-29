import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_approver/models/user_session.dart';
import 'package:vault_approver/services/secure_storage_service.dart';

UserSession _session() => UserSession(
      email: 'a@b.com',
      serverUrl: 'https://vault.example.com',
      accessToken: 'at',
      refreshToken: 'rt',
      accessTokenExpiry: DateTime.utc(2030),
    );

/// The shared mock store, except that listing it fails (one corrupt
/// EncryptedSharedPreferences entry makes `readAll` throw on Android).
class _UnlistableStorage extends FlutterSecureStorage {
  const _UnlistableStorage()
      : super(
          aOptions: SecureStorageService.androidOptions,
          iOptions: SecureStorageService.iosOptions,
        );

  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) =>
      throw PlatformException(code: 'corrupt', message: 'bad entry');
}

void main() {
  late SecureStorageService storage;
  late FlutterSecureStorage raw;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    raw = const FlutterSecureStorage();
    storage = SecureStorageService();
  });

  Future<void> seed() async {
    await storage.saveSession(_session());
    await storage.saveEncryptedUserKey('2.a|b|c');
    await storage.saveBiometricStorageKey('key');
    await storage.saveHistory(
      serverUrl: 'https://vault.example.com',
      email: 'a@b.com',
      json: '[]',
    );
    await storage.saveTwoFactorRememberToken(
      serverUrl: 'https://vault.example.com',
      email: 'a@b.com',
      token: 'remember',
    );
    await raw.write(key: 'auth_request_history', value: '[legacy]');
    await raw.write(
      key: 'client_cert|https://vault.example.com',
      value: '{"p12":""}',
    );
    await raw.write(key: 'client_ca|https://vault.example.com', value: 'pem');
  }

  test('device_id is stable', () async {
    final a = await storage.getOrCreateDeviceId();
    final b = await storage.getOrCreateDeviceId();
    expect(a, b);
    expect(a, hasLength(36));
  });

  test('clearSessionData keeps device_id and client certificates (A13, F6)',
      () async {
    final deviceId = await storage.getOrCreateDeviceId();
    await seed();
    await storage.clearSessionData();

    final all = await raw.readAll();
    expect(all['device_id'], deviceId);
    expect(all['client_cert|https://vault.example.com'], isNotNull);
    expect(all['client_ca|https://vault.example.com'], 'pem');
    expect(all.containsKey('session'), isFalse);
    expect(all.containsKey('encrypted_user_key'), isFalse);
    expect(all.containsKey('biometric_storage_key'), isFalse);
    expect(
        all.keys.where((k) => k.startsWith('auth_request_history')), isEmpty);
    expect(
        all.keys.where((k) => k.startsWith('two_factor_remember|')), isEmpty);
    expect(await storage.loadSession(), isNull);
    expect(await storage.hasCompletedSetup(), isFalse);
    expect(await storage.getOrCreateDeviceId(), deviceId);
  });

  test('clearSessionData deletes the account keys even if listing fails',
      () async {
    await seed();
    await SecureStorageService(storage: const _UnlistableStorage())
        .clearSessionData();
    final all = await raw.readAll();
    expect(all.containsKey('session'), isFalse);
    expect(
        all.keys.where((k) => k.startsWith('auth_request_history')), isEmpty);
    expect(
        all.keys.where((k) => k.startsWith('two_factor_remember|')), isEmpty);
    expect(all['client_ca|https://vault.example.com'], 'pem');
  });

  test('clearSessionData can keep 2FA remember tokens', () async {
    await seed();
    await storage.clearSessionData(keepTwoFactorRemember: true);
    expect(
      await storage.loadTwoFactorRememberToken(
        serverUrl: 'https://vault.example.com',
        email: 'A@B.com',
      ),
      'remember',
    );
  });

  group('reinstall (iOS keeps the keychain, not the preferences)', () {
    test('first start, restarts and an update never wipe', () async {
      // An update from a build without the marker: session etc. present.
      final deviceId = await storage.getOrCreateDeviceId();
      await seed();
      SharedPreferences.setMockInitialValues({'settings.theme_mode': 'dark'});
      final prefs = await SharedPreferences.getInstance();
      expect(await storage.wipeIfReinstalled(prefs), isFalse);
      expect(await storage.wipeIfReinstalled(prefs), isFalse);
      expect(await storage.loadSession(), isNotNull);
      expect(await storage.getOrCreateDeviceId(), deviceId);
      expect(prefs.getString(SecureStorageService.prefsInstallMarker),
          (await raw.readAll())[SecureStorageService.keyInstallMarker]);
    });

    test('keychain marker without the preferences marker → full wipe',
        () async {
      await storage.getOrCreateDeviceId();
      await seed();
      SharedPreferences.setMockInitialValues({});
      expect(
          await storage
              .wipeIfReinstalled(await SharedPreferences.getInstance()),
          isFalse);
      // Delete + install again: preferences are gone, the keychain is not.
      SharedPreferences.setMockInitialValues({});
      final fresh = await SharedPreferences.getInstance();
      expect(await storage.wipeIfReinstalled(fresh), isTrue);
      final all = await raw.readAll();
      expect(all.keys, [SecureStorageService.keyInstallMarker]);
      expect(all[SecureStorageService.keyInstallMarker],
          fresh.getString(SecureStorageService.prefsInstallMarker));
      expect(await storage.wipeIfReinstalled(fresh), isFalse);
    });

    test('a crash between the two writes never looks like a reinstall',
        () async {
      await seed();
      SharedPreferences.setMockInitialValues(
          {SecureStorageService.prefsInstallMarker: 'written-before-crash'});
      final prefs = await SharedPreferences.getInstance();
      expect(await storage.wipeIfReinstalled(prefs), isFalse);
      expect(await storage.loadSession(), isNotNull);
    });
  });

  test('clearAll wipes certificates but keeps device_id by default', () async {
    final deviceId = await storage.getOrCreateDeviceId();
    await seed();
    await storage.clearAll();
    final all = await raw.readAll();
    expect(all, {'device_id': deviceId});
    await storage.clearAll(keepDeviceId: false);
    expect(await raw.readAll(), isEmpty);
  });

  test('remember tokens are scoped per server and email', () async {
    await storage.saveTwoFactorRememberToken(
      serverUrl: 'https://vault.bitwarden.com/',
      email: ' User@Example.com ',
      token: 't-us',
    );
    await storage.saveTwoFactorRememberToken(
      serverUrl: 'https://vault.bitwarden.eu',
      email: 'user@example.com',
      token: 't-eu',
    );
    expect(
      await storage.loadTwoFactorRememberToken(
        serverUrl: 'vault.bitwarden.com',
        email: 'user@example.com',
      ),
      't-us',
    );
    expect(
      await storage.loadTwoFactorRememberToken(
        serverUrl: 'https://vault.bitwarden.eu',
        email: 'USER@example.com',
      ),
      't-eu',
    );
    expect(
      await storage.loadTwoFactorRememberToken(
        serverUrl: 'https://self.example.com',
        email: 'user@example.com',
      ),
      isNull,
    );
    expect(
      SecureStorageService.twoFactorRememberKey(
        'https://self.example.com:2053/',
        'A@b.com',
      ),
      'two_factor_remember|https://self.example.com:2053|a@b.com',
    );
    await storage.deleteTwoFactorRememberToken(
      serverUrl: 'https://vault.bitwarden.com',
      email: 'user@example.com',
    );
    expect(
      await storage.loadTwoFactorRememberToken(
        serverUrl: 'https://vault.bitwarden.com',
        email: 'user@example.com',
      ),
      isNull,
    );
  });

  test('history is scoped per server and email', () async {
    await storage.saveHistory(
      serverUrl: 'https://a.example.com',
      email: 'x@y.z',
      json: '[1]',
    );
    expect(
      await storage.loadHistory(
          serverUrl: 'https://a.example.com/', email: 'X@y.z'),
      '[1]',
    );
    expect(
      await storage.loadHistory(
          serverUrl: 'https://b.example.com', email: 'x@y.z'),
      isNull,
    );
  });

  test('a corrupt session entry reads as "no session"', () async {
    await raw.write(key: 'session', value: '{not json');
    expect(await storage.loadSession(), isNull);
    await storage.saveSession(_session());
    expect((await storage.loadSession())!.email, 'a@b.com');
  });
}
