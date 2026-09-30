import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_approver/models/user_session.dart';
import 'package:vault_approver/services/crypto_service.dart';
import 'package:vault_approver/services/pin_shift_vector_store.dart';
import 'package:vault_approver/services/secure_storage_service.dart';

import '../providers/provider_fakes.dart';

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

  // lockKeyMissing on 1.1.0: flutter_secure_storage 9.2.4 on iOS reads an
  // item it cannot access (keychain locked / protected data not available
  // yet) as null. A null must never be taken for "not stored".
  group('iOS keychain not available (read answers null)', () {
    late FakeAppleKeychain keychain;
    late SecureStorageService ios;

    setUp(() async {
      keychain = FakeAppleKeychain();
      ios = appleStorage(keychain);
      await seedAsBuild105(keychain, CryptoService(runKdfInIsolate: false));
    });

    for (final metadataReadable in [false, true]) {
      test(
          'stored secrets throw instead of reading as absent '
          '(containsKey ${metadataReadable ? 'answers' : 'fails'})', () async {
        keychain
          ..locked = true
          ..metadataReadableWhileLocked = metadataReadable;
        final unreadable = throwsA(isA<SecureStorageReadException>());
        await expectLater(ios.loadEncryptedUserKey(), unreadable);
        await expectLater(ios.loadBiometricStorageKey(), unreadable);
        await expectLater(ios.loadSession(), unreadable);
        await expectLater(ios.getOrCreateDeviceId(), unreadable);
        // Absent items cannot be told apart while locked either.
        keychain.items.remove(SecureStorageService.keyEncryptedUserKey);
        await expectLater(ios.loadEncryptedUserKey(), unreadable);

        keychain.locked = false;
        expect(await ios.loadEncryptedUserKey(), isNull); // really gone now
        expect(await ios.loadBiometricStorageKey(), isNotNull);
        expect((await ios.loadSession())!.email, kEmail);
        expect(await ios.getOrCreateDeviceId(),
            '5f0c1f7e-7d2a-4d5b-9a53-2d9b1c0e8f11');
      });
    }

    test('update from 1.0.5 (no marker anywhere) adopts a marker, no wipe',
        () async {
      SharedPreferences.setMockInitialValues({'settings.theme_mode': 'dark'});
      final prefs = await SharedPreferences.getInstance();
      final before = Map.of(keychain.items);
      expect(await ios.wipeIfReinstalled(prefs), isFalse);
      final marker = prefs.getString(SecureStorageService.prefsInstallMarker);
      expect(marker, isNotNull);
      expect(keychain.items[SecureStorageService.keyInstallMarker], marker);
      expect(await ios.wipeIfReinstalled(prefs), isFalse);
      expect(
        Map.of(keychain.items)..remove(SecureStorageService.keyInstallMarker),
        before,
      );
    });

    test('a start while the keychain is locked never causes a later wipe',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(await ios.wipeIfReinstalled(prefs), isFalse); // first start
      final marker = prefs.getString(SecureStorageService.prefsInstallMarker);

      // A start while the keychain cannot be read (main() swallows errors).
      keychain.locked = true;
      try {
        await ios.wipeIfReinstalled(prefs);
      } catch (_) {}
      expect(prefs.getString(SecureStorageService.prefsInstallMarker), marker,
          reason: 'the preferences marker is never replaced');

      keychain.locked = false;
      expect(await ios.wipeIfReinstalled(prefs), isFalse);
      expect(
          keychain.items[SecureStorageService.keyEncryptedUserKey], isNotNull);
      expect((await ios.loadSession())!.email, kEmail);
    });

    test('a lost or different keychain marker is re-adopted, never wiped',
        () async {
      SharedPreferences.setMockInitialValues(
          {SecureStorageService.prefsInstallMarker: 'prefs-marker'});
      final prefs = await SharedPreferences.getInstance();
      // No keychain marker (e.g. a failed write deleted it).
      expect(await ios.wipeIfReinstalled(prefs), isFalse);
      expect(keychain.items[SecureStorageService.keyInstallMarker],
          'prefs-marker');
      // A different one (the preferences were rewritten, the keychain not).
      keychain.items[SecureStorageService.keyInstallMarker] = 'stale';
      expect(await ios.wipeIfReinstalled(prefs), isFalse);
      expect(keychain.items[SecureStorageService.keyInstallMarker],
          'prefs-marker');
      expect(prefs.getString(SecureStorageService.prefsInstallMarker),
          'prefs-marker');
      expect(
          keychain.items[SecureStorageService.keyEncryptedUserKey], isNotNull);
    });

    test('delete + install again (no preferences marker) still wipes',
        () async {
      keychain.items[SecureStorageService.keyInstallMarker] = 'old-install';
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(await ios.wipeIfReinstalled(prefs), isTrue);
      expect(keychain.items.keys, [SecureStorageService.keyInstallMarker]);
      expect(keychain.items[SecureStorageService.keyInstallMarker],
          prefs.getString(SecureStorageService.prefsInstallMarker));
    });
  });

  // Write guard: flutter_secure_storage 9.2.4 writes an existing item as
  // update → delete → add; while the phone is locked only the delete works,
  // so a write used to delete the item (e.g. the session on a refresh).
  group('iOS keychain writes while protected data is unavailable', () {
    late FakeAppleKeychain keychain;
    late SecureStorageService ios;
    late UserSession refreshed;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      keychain = FakeAppleKeychain()..metadataReadableWhileLocked = true;
      ios = appleStorage(keychain);
      await seedAsBuild105(keychain, CryptoService(runKdfInIsolate: false));
      refreshed = testSession(accessToken: 'at-2', refreshToken: 'rt-2');
    });

    String? storedRefreshToken() {
      final raw = keychain.items[SecureStorageService.keySession];
      return raw == null
          ? null
          : UserSession.fromJson(jsonDecode(raw) as Map<String, dynamic>)
              .refreshToken;
    }

    test('nothing touches the keychain; reads see the owed values', () async {
      keychain.locked = true;
      await ios.saveSession(refreshed);
      await ios.saveHistory(serverUrl: kServer, email: kEmail, json: '[1]');
      await ios.saveTwoFactorRememberToken(
          serverUrl: kServer, email: kEmail, token: 'remember');
      await ios.deleteTwoFactorRememberToken(serverUrl: kServer, email: kEmail);
      expect(keychain.mutationsWhileLocked, 0);
      expect(storedRefreshToken(), 'rt-1');
      expect(ios.hasPendingChanges, isTrue);
      expect((await ios.loadSession())!.refreshToken, 'rt-2');
      expect(await ios.loadHistory(serverUrl: kServer, email: kEmail), '[1]');
      expect(
          await ios.loadTwoFactorRememberToken(
              serverUrl: kServer, email: kEmail),
          isNull);

      keychain.locked = false; // availability event → flush
      await pumpEventQueue();
      expect(ios.hasPendingChanges, isFalse);
      expect(storedRefreshToken(), 'rt-2');
      expect(keychain.items[SecureStorageService.historyKey(kServer, kEmail)],
          '[1]');
      expect(
          keychain.items.keys.where((k) =>
              k.startsWith(SecureStorageService.twoFactorRememberPrefix)),
          isEmpty);
    });

    test('without the availability event, the next access flushes', () async {
      keychain
        ..availabilityEvents = false
        ..locked = true;
      await ios.saveSession(refreshed);
      keychain.locked = false;
      await pumpEventQueue();
      expect(storedRefreshToken(), 'rt-1', reason: 'no event arrived');
      expect((await ios.loadSession())!.refreshToken, 'rt-2');
      expect(storedRefreshToken(), 'rt-2');
      expect(ios.hasPendingChanges, isFalse);
    });

    test('the device locking mid-write: the lost item is restored', () async {
      // Available at the check, locked by the time the plugin writes.
      keychain.beforeMutation = () => keychain.locked = true;
      await expectLater(ios.saveSession(refreshed), throwsA(anything));
      keychain.beforeMutation = null;
      expect(
          keychain.items.containsKey(SecureStorageService.keySession), isFalse,
          reason: 'the plugin deleted it');
      expect((await ios.loadSession())!.refreshToken, 'rt-2');

      keychain.locked = false;
      await pumpEventQueue();
      expect(storedRefreshToken(), 'rt-2');
    });

    test('a sign-out while locked is owed, then complete', () async {
      final prefs = await SharedPreferences.getInstance();
      keychain.items['${SecureStorageService.clientCertPrefix}$kServer'] = '{}';
      keychain.items[SecureStorageService.keyInstallMarker] = 'marker';
      keychain.items[SecureStorageService.historyKey(kServer, kEmail)] = '[]';
      keychain.locked = true;
      await ios.clearSessionData(session: testSession());
      expect(keychain.mutationsWhileLocked, 0);
      expect(keychain.items[SecureStorageService.keySession], isNotNull);
      expect(prefs.getString(SecureStorageService.prefsPendingSignOut), 'all');
      expect(await ios.loadSession(), isNull);
      expect(await ios.loadHistory(serverUrl: kServer, email: kEmail), isNull);
      // Writes after the sign-out come after it.
      await ios.saveHistory(serverUrl: kServer, email: kEmail, json: '[2]');

      keychain.locked = false;
      await pumpEventQueue();
      expect(keychain.items.keys.toSet(), {
        SecureStorageService.keyDeviceId,
        '${SecureStorageService.clientCertPrefix}$kServer',
        SecureStorageService.keyInstallMarker,
        SecureStorageService.historyKey(kServer, kEmail),
      });
      expect(keychain.items[SecureStorageService.historyKey(kServer, kEmail)],
          '[2]');
      expect(prefs.getString(SecureStorageService.prefsPendingSignOut), isNull);
      expect(ios.hasPendingChanges, isFalse);
    });

    test('an owed sign-out outlives the process', () async {
      final prefs = await SharedPreferences.getInstance();
      keychain.locked = true;
      await ios.clearSessionData(keepTwoFactorRemember: true);
      // A new process, still locked: signed out, nothing touched.
      final next = appleStorage(keychain);
      expect(await next.loadSession(), isNull);
      expect(keychain.items[SecureStorageService.keySession], isNotNull);
      // Unlocked: the next start finishes it before anything else.
      keychain
        ..availabilityEvents = false
        ..locked = false;
      final later = appleStorage(keychain);
      expect(await later.wipeIfReinstalled(prefs), isFalse);
      expect(
          keychain.items.containsKey(SecureStorageService.keySession), isFalse);
      expect(
          keychain.items.containsKey(SecureStorageService.keyEncryptedUserKey),
          isFalse);
      expect(keychain.items[SecureStorageService.keyDeviceId], isNotNull);
      expect(prefs.getString(SecureStorageService.prefsPendingSignOut), isNull);
      expect(keychain.mutationsWhileLocked, 0);
    });

    test('clearAll while locked touches nothing and throws', () async {
      final before = Map.of(keychain.items);
      keychain.locked = true;
      await expectLater(
          ios.clearAll(), throwsA(isA<SecureStorageReadException>()));
      expect(keychain.items, before);
      expect(keychain.mutationsWhileLocked, 0);
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

  // PIN Shift's remembered vector: device data, not vault account data.
  group('PIN Shift vector', () {
    const key = SecureStorageService.keyPinShiftVector;

    test('save, load, replace, delete', () async {
      expect(key, 'pin_shift_vector');
      expect(await storage.loadShiftVector(), isNull);
      await storage.saveShiftVector('11111111');
      expect(await storage.loadShiftVector(), '11111111');
      expect((await raw.readAll())[key], '11111111');
      await storage.saveShiftVector('3719');
      expect(await storage.loadShiftVector(), '3719');
      await storage.deleteShiftVector();
      expect(await storage.loadShiftVector(), isNull);
      expect((await raw.readAll()).containsKey(key), isFalse);
      await storage.deleteShiftVector(); // nothing saved: no error
    });

    test('never in SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      await storage.saveShiftVector('90817263');
      await storage.getOrCreateDeviceId();
      final prefs = await SharedPreferences.getInstance();
      for (final k in prefs.getKeys()) {
        expect('${prefs.get(k)}', isNot(contains('90817263')), reason: k);
      }
    });

    for (final keep2fa in [false, true]) {
      test('kept by clearSessionData (keepTwoFactorRemember: $keep2fa)',
          () async {
        await seed();
        await storage.saveShiftVector('90817263');
        await storage.clearSessionData(keepTwoFactorRemember: keep2fa);
        expect(await storage.loadSession(), isNull);
        expect(await storage.loadShiftVector(), '90817263');
        expect((await raw.readAll())[key], '90817263');
      });
    }

    test('removed by clearAll, with or without the device id', () async {
      await seed();
      await storage.saveShiftVector('90817263');
      await storage.clearAll();
      expect(await storage.loadShiftVector(), isNull);
      expect((await raw.readAll()).containsKey(key), isFalse);
      await storage.saveShiftVector('1234');
      await storage.clearAll(keepDeviceId: false);
      expect(await raw.readAll(), isEmpty);
    });

    test('removed by the reinstall wipe', () async {
      await storage.saveShiftVector('90817263');
      SharedPreferences.setMockInitialValues({});
      expect(
          await storage
              .wipeIfReinstalled(await SharedPreferences.getInstance()),
          isFalse);
      expect(await storage.loadShiftVector(), '90817263');
      // Delete + install again: the keychain kept it, the preferences not.
      SharedPreferences.setMockInitialValues({});
      expect(
          await storage
              .wipeIfReinstalled(await SharedPreferences.getInstance()),
          isTrue);
      expect(await storage.loadShiftVector(), isNull);
    });

    test('the keychain store behind PIN Shift is this service', () {
      expect(storage, isA<PinShiftVectorStore>());
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(container.read(pinShiftVectorStoreProvider), isNull,
          reason: 'main() wires it to the app\'s SecureStorageService');
    });

    group('iOS, protected data unavailable', () {
      late FakeAppleKeychain keychain;
      late SecureStorageService ios;

      setUp(() {
        SharedPreferences.setMockInitialValues({});
        keychain = FakeAppleKeychain()..metadataReadableWhileLocked = true;
        ios = appleStorage(keychain);
      });

      test('a saved vector that cannot be read throws, never "none"', () async {
        await ios.saveShiftVector('90817263');
        for (final metadataReadable in [true, false]) {
          keychain
            ..locked = true
            ..metadataReadableWhileLocked = metadataReadable;
          await expectLater(ios.loadShiftVector(),
              throwsA(isA<SecureStorageReadException>()));
          keychain.locked = false;
        }
        expect(await ios.loadShiftVector(), '90817263');
      });

      test('save and delete are owed, then applied in order', () async {
        keychain.locked = true;
        await ios.saveShiftVector('90817263');
        expect(keychain.mutationsWhileLocked, 0);
        expect(keychain.items.containsKey(key), isFalse);
        expect(await ios.loadShiftVector(), '90817263');
        keychain.locked = false;
        await pumpEventQueue();
        expect(keychain.items[key], '90817263');

        keychain.locked = true;
        await ios.deleteShiftVector();
        expect(keychain.items[key], '90817263');
        expect(await ios.loadShiftVector(), isNull);
        keychain.locked = false;
        await pumpEventQueue();
        expect(keychain.items.containsKey(key), isFalse);
        expect(ios.hasPendingChanges, isFalse);
      });

      test('an owed sign-out keeps an owed vector and the stored one',
          () async {
        keychain.items[key] = '1111';
        await seedAsBuild105(keychain, CryptoService(runKdfInIsolate: false));
        keychain.locked = true;
        await ios.saveShiftVector('90817263');
        await ios.clearSessionData(session: testSession());
        expect(await ios.loadSession(), isNull);
        expect(await ios.loadShiftVector(), '90817263');
        keychain.locked = false;
        await pumpEventQueue();
        expect(keychain.items.containsKey(SecureStorageService.keySession),
            isFalse);
        expect(keychain.items[key], '90817263');
      });
    });
  });
}
