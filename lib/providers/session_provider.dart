import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../demo_fixtures.dart';
import '../models/cipher_string.dart';
import '../models/user_session.dart';
import 'service_providers.dart';

/// Holds the decrypted UserKey in memory after biometric unlock.
/// Null means locked / not set up.
final userKeyProvider = StateProvider<Uint8List?>((_) => null);

/// Manages session lifecycle: setup, biometric unlock, logout.
final sessionProvider =
    AsyncNotifierProvider<SessionNotifier, UserSession?>(SessionNotifier.new);

class SessionNotifier extends AsyncNotifier<UserSession?> {
  @override
  Future<UserSession?> build() async {
    // Runtime/compile-time demo: hand back a fake session so the app routes
    // straight into the (fixture-backed) RequestsScreen — no storage, no API.
    if (demoActive) return demoSession();
    final storage = ref.read(secureStorageProvider);
    return storage.loadSession();
  }

  /// Full first-time setup: prelogin → derive keys → login → store.
  /// Returns the decrypted UserKey (64 bytes).
  /// Throws [TwoFactorRequiredException] if 2FA is needed (caller should
  /// re-call with [twoFactorToken] and [twoFactorProvider]).
  Future<Uint8List> setup({
    required String serverUrl,
    required String email,
    required String masterPassword,
    required void Function(String status) onProgress,
    String? twoFactorToken,
    int? twoFactorProvider,
  }) async {
    final crypto = ref.read(cryptoServiceProvider);
    final api = ref.read(apiServiceProvider);
    final storage = ref.read(secureStorageProvider);

    // 1. Get KDF params
    onProgress('Getting server parameters...');
    final kdf = await api.prelogin(serverUrl, email);

    // 2. Derive masterKey
    onProgress('Deriving master key...');
    final masterKey = await crypto.deriveMasterKey(email, masterPassword, kdf);

    // 3. Stretch to 64 bytes
    final stretchedMasterKey = crypto.stretchMasterKey(masterKey);

    // 4. Derive password hash for server auth
    onProgress('Authenticating...');
    final masterPasswordHash =
        await crypto.deriveMasterPasswordHash(masterKey, masterPassword);
    final hashB64 = base64Encode(masterPasswordHash);

    // 5. Login (may throw TwoFactorRequiredException)
    final deviceId = await storage.getOrCreateDeviceId();
    final loginResult = await api.login(
      serverUrl: serverUrl,
      email: email,
      masterPasswordHashB64: hashB64,
      deviceId: deviceId,
      twoFactorToken: twoFactorToken,
      twoFactorProvider: twoFactorProvider,
    );

    final accessToken = loginResult['access_token'] as String;
    final refreshToken = loginResult['refresh_token'] as String;
    final expiresIn = loginResult['expires_in'] as int? ?? 3600;
    final protectedKeyStr =
        loginResult['Key'] as String? ?? loginResult['key'] as String;

    // 6. Decrypt protectedSymmetricKey → userKey
    onProgress('Decrypting encryption key...');
    final protectedKey = CipherString.parse(protectedKeyStr);
    final userKey = crypto.decryptUserKey(protectedKey, stretchedMasterKey);

    // 7. Encrypt userKey for biometric storage
    onProgress('Securing keys...');
    final storageKey = _generateStorageKey(crypto);
    final encryptedUserKey = crypto.encryptSymmetric(userKey, storageKey);

    // 8. Persist everything
    await storage.saveEncryptedUserKey(encryptedUserKey.encode());
    await storage.saveBiometricStorageKey(base64Encode(storageKey));

    final session = UserSession(
      email: email,
      serverUrl: serverUrl,
      accessToken: accessToken,
      refreshToken: refreshToken,
      accessTokenExpiry: DateTime.now().add(Duration(seconds: expiresIn)),
    );
    await storage.saveSession(session);

    // Configure API with session
    api.configure(serverUrl, session);

    // Set state
    state = AsyncData(session);
    ref.read(userKeyProvider.notifier).state = userKey;
    ref.read(isLockedProvider.notifier).state = false;

    return userKey;
  }

  /// Biometric unlock: authenticate → decrypt UserKey from storage.
  Future<Uint8List> unlockWithBiometrics() async {
    final biometric = ref.read(biometricServiceProvider);
    final storage = ref.read(secureStorageProvider);
    final crypto = ref.read(cryptoServiceProvider);

    final authenticated = await biometric.authenticate();
    if (!authenticated) throw Exception('Biometric authentication failed');

    final encryptedStr = await storage.loadEncryptedUserKey();
    final storageKeyB64 = await storage.loadBiometricStorageKey();

    if (encryptedStr == null || storageKeyB64 == null) {
      throw StateError('Setup not completed');
    }

    final storageKey = base64Decode(storageKeyB64);
    final encrypted = CipherString.parse(encryptedStr);
    final userKey = crypto.decryptSymmetric(encrypted, Uint8List.fromList(storageKey));

    // Configure API
    final session = await storage.loadSession();
    if (session != null) {
      final api = ref.read(apiServiceProvider);
      api.configure(session.serverUrl, session);
      state = AsyncData(session);
    }

    ref.read(userKeyProvider.notifier).state = userKey;
    return userKey;
  }

  /// Lock: zero the UserKey in memory.
  void lock() {
    final key = ref.read(userKeyProvider);
    if (key != null) {
      key.fillRange(0, key.length, 0);
    }
    ref.read(userKeyProvider.notifier).state = null;
  }

  /// Logout: clear everything.
  Future<void> logout() async {
    // Leaving a runtime demo → back to a real (logged-out) setup screen.
    demoRuntime.value = false;
    lock();
    final storage = ref.read(secureStorageProvider);
    await storage.clearAll();
    ref.read(notificationServiceProvider).disconnect();
    state = const AsyncData(null);
  }

  Uint8List _generateStorageKey(dynamic crypto) {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(64, (_) => rng.nextInt(256)));
  }
}
