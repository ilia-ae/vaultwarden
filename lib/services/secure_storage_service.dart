import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/server_environment.dart';
import '../models/user_session.dart';

/// Reading the keychain / keystore failed (device locked, keystore reset…).
/// Distinct from "no session stored" (R4).
class SecureStorageReadException implements Exception {
  const SecureStorageReadException(this.cause);
  final Object cause;
  @override
  String toString() => 'SecureStorageReadException($cause)';
}

/// All secrets of the app live here (keychain / EncryptedSharedPreferences).
///
/// Data classes and what the two clear operations do:
///
/// | key(s)                         | clearSessionData | clearAll |
/// |--------------------------------|------------------|----------|
/// | session, encrypted user key,   | deleted          | deleted  |
/// |   biometric storage key        |                  |          |
/// | history (`auth_request_history*`)| deleted        | deleted  |
/// | 2FA remember tokens            | deleted (opt.)   | deleted  |
/// | device_id                      | kept             | kept (opt.) |
/// | client certificates (`client_cert|*`, `client_ca|*`) | kept | deleted |
/// | install marker                 | kept             | deleted  |
///
/// Preferences live in SharedPreferences; the only one used here is the
/// install marker of [wipeIfReinstalled].
class SecureStorageService {
  SecureStorageService({
    FlutterSecureStorage? storage,
    FlutterSecureStorage? legacyDefaultStorage,
  })  : _storage = storage ?? defaultStorage,
        _legacyStorage = legacyDefaultStorage ?? const FlutterSecureStorage();

  /// Options shared by every secure item of the app (use them for any new
  /// secure storage, e.g. history and client certificates).
  static const AndroidOptions androidOptions =
      AndroidOptions(encryptedSharedPreferences: true);
  static const IOSOptions iosOptions = IOSOptions(
    accessibility: KeychainAccessibility.passcode,
  );
  static const FlutterSecureStorage defaultStorage = FlutterSecureStorage(
    aOptions: androidOptions,
    iOptions: iosOptions,
  );

  /// Same random value in the keychain and in SharedPreferences; see
  /// [wipeIfReinstalled].
  static const keyInstallMarker = 'install_marker';
  static const prefsInstallMarker = 'app.install_marker';

  static const keySession = 'session';
  static const keyEncryptedUserKey = 'encrypted_user_key';
  static const keyBiometricStorageKey = 'biometric_storage_key';
  static const keyDeviceId = 'device_id';

  /// History keys: `auth_request_history|<scope>|<email>`; the legacy
  /// unscoped key `auth_request_history` (written with default options by
  /// older builds) is migrated once into the signed-in account (see
  /// [readLegacyHistory]) and removed by both clear operations and by a new
  /// sign-in.
  static const historyKeyPrefix = 'auth_request_history';
  static const twoFactorRememberPrefix = 'two_factor_remember|';

  /// Owned by ClientCertService; listed here for the clear semantics.
  static const clientCertPrefix = 'client_cert|';
  static const clientCaPrefix = 'client_ca|';

  final FlutterSecureStorage _storage;
  final FlutterSecureStorage _legacyStorage;

  // ── Session ──

  Future<void> saveSession(UserSession session) async {
    await _storage.write(
      key: keySession,
      value: jsonEncode(session.toJson()),
    );
  }

  /// Null when no (valid) session is stored. Throws
  /// [SecureStorageReadException] when the keychain itself fails, so callers
  /// can tell "logged out" from "keychain temporarily unavailable".
  Future<UserSession?> loadSession() async {
    final String? raw;
    try {
      raw = await _storage.read(key: keySession);
    } on PlatformException catch (e) {
      throw SecureStorageReadException(e);
    }
    if (raw == null) return null;
    try {
      return UserSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null; // corrupt entry = no usable session
    }
  }

  Future<void> deleteSession() async {
    await _storage.delete(key: keySession);
  }

  // ── Encrypted UserKey ──

  Future<void> saveEncryptedUserKey(String cipherString) async {
    await _storage.write(key: keyEncryptedUserKey, value: cipherString);
  }

  Future<String?> loadEncryptedUserKey() async {
    return _storage.read(key: keyEncryptedUserKey);
  }

  // ── Biometric Storage Key ──

  Future<void> saveBiometricStorageKey(String base64Key) async {
    await _storage.write(key: keyBiometricStorageKey, value: base64Key);
  }

  Future<String?> loadBiometricStorageKey() async {
    return _storage.read(key: keyBiometricStorageKey);
  }

  // ── Device ID ──

  /// The app's stable Bitwarden `deviceIdentifier`. Survives logout and
  /// [clearAll] (like the official apps' appId), so re-logins are not "new
  /// devices" (new-device verification, 2FA remember, one device row).
  Future<String> getOrCreateDeviceId() async {
    var id = await _storage.read(key: keyDeviceId);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await _storage.write(key: keyDeviceId, value: id);
    }
    return id;
  }

  // ── 2FA "remember this device" tokens (per server + email) ──

  static String twoFactorRememberKey(String serverUrl, String email) =>
      '$twoFactorRememberPrefix${_scope(serverUrl)}|${_normEmail(email)}';

  Future<void> saveTwoFactorRememberToken({
    required String serverUrl,
    required String email,
    required String token,
  }) async {
    await _storage.write(
      key: twoFactorRememberKey(serverUrl, email),
      value: token,
    );
  }

  Future<String?> loadTwoFactorRememberToken({
    required String serverUrl,
    required String email,
  }) async {
    return _storage.read(key: twoFactorRememberKey(serverUrl, email));
  }

  Future<void> deleteTwoFactorRememberToken({
    required String serverUrl,
    required String email,
  }) async {
    await _storage.delete(key: twoFactorRememberKey(serverUrl, email));
  }

  // ── Approve/deny history (per server + email) ──

  static String historyKey(String serverUrl, String email) =>
      '$historyKeyPrefix|${_scope(serverUrl)}|${_normEmail(email)}';

  Future<String?> loadHistory({
    required String serverUrl,
    required String email,
  }) async {
    return _storage.read(key: historyKey(serverUrl, email));
  }

  Future<void> saveHistory({
    required String serverUrl,
    required String email,
    required String json,
  }) async {
    await _storage.write(key: historyKey(serverUrl, email), value: json);
  }

  Future<void> deleteHistory({
    required String serverUrl,
    required String email,
  }) async {
    await _storage.delete(key: historyKey(serverUrl, email));
  }

  /// The unscoped history of builds before per-account history (F13), or
  /// null. Only meaningful for the session that was signed in when the app
  /// was updated: a new sign-in deletes it ([deleteLegacyHistory]).
  Future<String?> readLegacyHistory() async {
    for (final store in [_legacyStorage, _storage]) {
      try {
        final raw = await store.read(key: historyKeyPrefix);
        if (raw != null && raw.trim().isNotEmpty) return raw;
      } catch (_) {
        // unreadable = nothing to migrate
      }
    }
    return null;
  }

  /// Deletes the unscoped history of older builds (best effort).
  Future<void> deleteLegacyHistory() => _deleteLegacyHistory();

  // ── Setup check ──

  Future<bool> hasCompletedSetup() async {
    final key = await _storage.read(key: keyEncryptedUserKey);
    final session = await _storage.read(key: keySession);
    return key != null && session != null;
  }

  // ── Reinstall ──

  /// iOS keeps keychain items when the app is deleted, SharedPreferences
  /// not. A keychain marker without the matching preferences marker
  /// therefore means "deleted and installed again": everything in the store
  /// (session, keys, device_id, certificates) is wiped, as a fresh install
  /// promises. Builds before this marker never wrote it, so updating from
  /// them never wipes. Call once at startup, before anything reads the
  /// store. Returns true when it wiped.
  Future<bool> wipeIfReinstalled(SharedPreferences prefs) async {
    final local = prefs.getString(prefsInstallMarker);
    final String? stored;
    try {
      stored = await _storage.read(key: keyInstallMarker);
    } catch (_) {
      return false; // keychain unavailable: decide on a later start
    }
    var wiped = false;
    if (stored != null && stored != local) {
      await clearAll(keepDeviceId: false);
      wiped = true;
    }
    if (stored == null || wiped) {
      final marker = const Uuid().v4();
      // Preferences first: a crash in between then only means "no keychain
      // marker yet" (no wipe) on the next start, never a false reinstall.
      if (await prefs.setString(prefsInstallMarker, marker)) {
        await _storage.write(key: keyInstallMarker, value: marker);
      }
    }
    return wiped;
  }

  // ── Clearing ──

  /// Logout / session end (A13): deletes session, keys, history and (unless
  /// [keepTwoFactorRemember]) 2FA remember tokens. KEEPS `device_id` and the
  /// per-server client certificates. Preferences are not in this store.
  ///
  /// [session] (default: the stored one) names the account whose history
  /// and remember token are deleted by key even when listing the store
  /// fails (e.g. one corrupt EncryptedSharedPreferences entry).
  Future<void> clearSessionData({
    bool keepTwoFactorRemember = false,
    UserSession? session,
  }) async {
    UserSession? account = session;
    if (account == null) {
      try {
        account = await loadSession();
      } catch (_) {
        account = null;
      }
    }
    await _storage.delete(key: keySession);
    await _storage.delete(key: keyEncryptedUserKey);
    await _storage.delete(key: keyBiometricStorageKey);
    final doomed = <String>{
      for (final key in await _readAllKeys())
        if (key.startsWith(historyKeyPrefix) ||
            (key.startsWith(twoFactorRememberPrefix) && !keepTwoFactorRemember))
          key,
      if (account != null) historyKey(account.serverUrl, account.email),
      if (account != null && !keepTwoFactorRemember)
        twoFactorRememberKey(account.serverUrl, account.email),
    };
    Object? failure;
    for (final key in doomed) {
      try {
        await _storage.delete(key: key);
      } catch (e) {
        failure ??= e; // keep deleting the others
      }
    }
    await _deleteLegacyHistory();
    if (failure != null) throw failure;
  }

  /// Full reset: everything in the secure store including client
  /// certificates. `device_id` survives unless [keepDeviceId] is false.
  Future<void> clearAll({bool keepDeviceId = true}) async {
    String? deviceId;
    if (keepDeviceId) {
      try {
        deviceId = await _storage.read(key: keyDeviceId);
      } catch (_) {
        deviceId = null;
      }
    }
    await _storage.deleteAll();
    if (deviceId != null && deviceId.isNotEmpty) {
      await _storage.write(key: keyDeviceId, value: deviceId);
    }
    await _deleteLegacyHistory();
  }

  Future<Iterable<String>> _readAllKeys() async {
    try {
      return (await _storage.readAll()).keys.toList();
    } catch (_) {
      return const [];
    }
  }

  /// Older builds wrote history with default options (different iOS
  /// accessibility, so a deleteAll with our options would not remove it; on
  /// Android the plugin may have moved it into the encrypted store).
  Future<void> _deleteLegacyHistory() async {
    for (final store in [_legacyStorage, _storage]) {
      try {
        await store.delete(key: historyKeyPrefix);
      } catch (_) {
        // best effort
      }
    }
  }

  static String _scope(String serverUrl) {
    try {
      return ServerEnvironment.fromUrl(serverUrl).storageScope;
    } on FormatException {
      return serverUrl.trim().toLowerCase();
    }
  }

  static String _normEmail(String email) => email.trim().toLowerCase();
}
