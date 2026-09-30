import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
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
///
/// Reading the items an account cannot do without (session, user key,
/// biometric storage key, device_id, install marker) never mistakes an
/// unreadable keychain for an empty one: see [_readRequired].
///
/// Write guard (iOS): flutter_secure_storage 9.2.x (and 11.x) writes an
/// existing item as update → on failure delete → add. While protected data
/// is unavailable (device locked) the update and the add fail but the delete
/// does not, so a write then silently DELETES the item (e.g. the session on
/// a token refresh right after the app went to the background). So before
/// every write or delete this service checks
/// `UIApplication.isProtectedDataAvailable`; while it is false nothing
/// touches the keychain: the change is kept in memory ("owed"), reads return
/// it, and it is applied in order once protected data is available again —
/// before the next read or write, on resume ([flushPending]) and on the
/// plugin's availability event. A write that fails anyway is owed too. A
/// sign-out that could not run is also recorded in the preferences
/// ([prefsPendingSignOut]) so it still happens after the process ends.
class SecureStorageService {
  SecureStorageService({
    FlutterSecureStorage? storage,
    FlutterSecureStorage? legacyDefaultStorage,
    bool? iosDataProtection,
    Future<SharedPreferences> Function()? preferences,
  })  : _storage = storage ?? defaultStorage,
        _legacyStorage = legacyDefaultStorage ?? const FlutterSecureStorage(),
        _guardWrites = iosDataProtection ?? (!kIsWeb && Platform.isIOS),
        _preferences = preferences ?? SharedPreferences.getInstance;

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

  /// A sign-out whose keychain deletes are still owed: `all`, or `keep_2fa`
  /// (2FA remember tokens kept). No secrets.
  static const prefsPendingSignOut = 'app.pending_sign_out';

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
  final bool _guardWrites;
  final Future<SharedPreferences> Function() _preferences;

  // ── Owed changes (write guard) ──

  /// Writes (value) and deletes (null) still owed to the keychain, applied
  /// after [_owedSignOutKeep2fa].
  final Map<String, String?> _owedWrites = {};

  /// Non-null: a sign-out is owed; true = keep the 2FA remember tokens.
  bool? _owedSignOutKeep2fa;
  UserSession? _owedSignOutAccount;
  int _signOutGeneration = 0;
  bool _owedLegacyHistoryDelete = false;
  Future<void>? _durableLoad;
  Future<void>? _flushing;
  StreamSubscription<bool>? _availability;

  /// True while changes are owed to the keychain.
  bool get hasPendingChanges =>
      _owedWrites.isNotEmpty ||
      _owedSignOutKeep2fa != null ||
      _owedLegacyHistoryDelete;

  /// Applies owed changes when protected data is available (call on
  /// resume). Never throws; what still fails stays owed.
  Future<void> flushPending() => _settle();

  // ── Session ──

  /// Held in memory while the keychain cannot take it (see the class doc):
  /// the caller's in-memory session stays the authority until then.
  Future<void> saveSession(UserSession session) =>
      _change(keySession, jsonEncode(session.toJson()));

  /// Null when no (valid) session is stored. Throws
  /// [SecureStorageReadException] when the keychain itself fails, so callers
  /// can tell "logged out" from "keychain temporarily unavailable".
  Future<UserSession?> loadSession() async {
    final raw = await _readRequired(keySession);
    if (raw == null) return null;
    try {
      return UserSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null; // corrupt entry = no usable session
    }
  }

  Future<void> deleteSession() => _change(keySession, null);

  // ── Encrypted UserKey ──

  Future<void> saveEncryptedUserKey(String cipherString) =>
      _change(keyEncryptedUserKey, cipherString);

  /// Null only when no key is stored; throws [SecureStorageReadException]
  /// when the keychain cannot be read (see [_readRequired]).
  Future<String?> loadEncryptedUserKey() => _readRequired(keyEncryptedUserKey);

  // ── Biometric Storage Key ──

  Future<void> saveBiometricStorageKey(String base64Key) =>
      _change(keyBiometricStorageKey, base64Key);

  /// Null only when no key is stored; throws [SecureStorageReadException]
  /// when the keychain cannot be read (see [_readRequired]).
  Future<String?> loadBiometricStorageKey() =>
      _readRequired(keyBiometricStorageKey);

  // ── Device ID ──

  /// The app's stable Bitwarden `deviceIdentifier`. Survives logout and
  /// [clearAll] (like the official apps' appId), so re-logins are not "new
  /// devices" (new-device verification, 2FA remember, one device row).
  /// A keychain that cannot be read throws [SecureStorageReadException]
  /// rather than getting a new id.
  Future<String> getOrCreateDeviceId() async {
    var id = await _readRequired(keyDeviceId);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      await _change(keyDeviceId, id);
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
  }) =>
      _change(twoFactorRememberKey(serverUrl, email), token);

  Future<String?> loadTwoFactorRememberToken({
    required String serverUrl,
    required String email,
  }) =>
      _readOptional(twoFactorRememberKey(serverUrl, email));

  Future<void> deleteTwoFactorRememberToken({
    required String serverUrl,
    required String email,
  }) =>
      _change(twoFactorRememberKey(serverUrl, email), null);

  // ── Approve/deny history (per server + email) ──

  static String historyKey(String serverUrl, String email) =>
      '$historyKeyPrefix|${_scope(serverUrl)}|${_normEmail(email)}';

  Future<String?> loadHistory({
    required String serverUrl,
    required String email,
  }) =>
      _readOptional(historyKey(serverUrl, email));

  Future<void> saveHistory({
    required String serverUrl,
    required String email,
    required String json,
  }) =>
      _change(historyKey(serverUrl, email), json);

  Future<void> deleteHistory({
    required String serverUrl,
    required String email,
  }) =>
      _change(historyKey(serverUrl, email), null);

  /// The unscoped history of builds before per-account history (F13), or
  /// null. Only meaningful for the session that was signed in when the app
  /// was updated: a new sign-in deletes it ([deleteLegacyHistory]).
  Future<String?> readLegacyHistory() async {
    await _settle();
    if (_owedLegacyHistoryDelete || _owedSignOutKeep2fa != null) return null;
    if (_owedWrites.containsKey(historyKeyPrefix)) {
      return _owedWrites[historyKeyPrefix];
    }
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

  /// Deletes the unscoped history of older builds (best effort; owed while
  /// the keychain cannot take it).
  Future<void> deleteLegacyHistory() async {
    if (await _readyToWrite()) {
      await _deleteLegacyHistory();
    } else {
      _owedLegacyHistoryDelete = true;
      _watchAvailability();
    }
  }

  // ── Setup check ──

  Future<bool> hasCompletedSetup() async {
    final key = await loadEncryptedUserKey();
    final session = await _readRequired(keySession);
    return key != null && session != null;
  }

  // ── Reinstall ──

  /// iOS keeps keychain items when the app is deleted, SharedPreferences
  /// not. A keychain marker while the preferences have none therefore means
  /// "deleted and installed again": everything in the store (session, keys,
  /// device_id, certificates) is wiped, as a fresh install promises. Call
  /// once at startup, before anything reads the store. Returns true when it
  /// wiped.
  ///
  /// Never a wipe otherwise:
  /// - no marker anywhere (fresh install, or an update from a build before
  ///   the marker such as 1.0.5): a new marker is adopted;
  /// - keychain unreadable (locked): nothing is decided or written;
  /// - preferences marker set: it is authoritative and never replaced; a
  ///   missing or different keychain marker is rewritten from it. (Replacing
  ///   it after a keychain read that wrongly came back empty left the two
  ///   markers different, and the next start wiped a signed-in account.)
  Future<bool> wipeIfReinstalled(SharedPreferences prefs) async {
    final String? stored;
    try {
      // A sign-out owed by the previous run happens first.
      await _settle();
      stored = await _readRequired(keyInstallMarker);
    } catch (_) {
      return false; // keychain unavailable: decide on a later start
    }
    var local = prefs.getString(prefsInstallMarker);
    if (stored != null && local == null) {
      // Confirm with the preferences on disk before wiping anything.
      await prefs.reload();
      local = prefs.getString(prefsInstallMarker);
    }
    if (local != null) {
      if (stored != local) await _change(keyInstallMarker, local);
      return false;
    }
    final wiped = stored != null;
    // Throws (nothing touched, no preferences marker written) when the
    // keychain cannot take it: the next start decides again.
    if (wiped) await clearAll(keepDeviceId: false);
    final marker = const Uuid().v4();
    // Preferences first: a crash in between then only means "no keychain
    // marker yet", which the next start fills in from the preferences.
    if (await prefs.setString(prefsInstallMarker, marker)) {
      await _change(keyInstallMarker, marker);
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
  ///
  /// All or nothing for the caller: when the keychain cannot take the
  /// deletes now (iOS: protected data unavailable) or one fails, the whole
  /// sign-out is owed — reads already answer "signed out" — and rerun until
  /// it completes, after a restart too ([prefsPendingSignOut]). Never
  /// throws, and never touches the install marker (a sign-out can never
  /// look like a reinstall).
  Future<void> clearSessionData({
    bool keepTwoFactorRemember = false,
    UserSession? session,
  }) async {
    await _settle();
    // Owed changes this sign-out removes are void.
    _owedWrites
        .removeWhere((key, _) => _signOutDeletes(key, keepTwoFactorRemember));
    if (_guardWrites && !await _available()) {
      await _oweSignOut(keepTwoFactorRemember, session);
      return;
    }
    try {
      await _clearSessionNow(keepTwoFactorRemember, session);
    } catch (_) {
      await _oweSignOut(keepTwoFactorRemember, session);
    }
  }

  Future<void> _clearSessionNow(
    bool keepTwoFactorRemember,
    UserSession? session,
  ) async {
    UserSession? account = session;
    if (account == null) {
      try {
        final raw = await _readVerified(keySession);
        account = raw == null
            ? null
            : UserSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
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
  /// Throws [SecureStorageReadException] without touching anything while
  /// the keychain cannot take it (iOS: protected data unavailable).
  Future<void> clearAll({bool keepDeviceId = true}) async {
    await _settle();
    if (_guardWrites && !await _available()) {
      throw const SecureStorageReadException('protected data unavailable');
    }
    String? deviceId;
    if (keepDeviceId) {
      try {
        deviceId = _owedWrites.containsKey(keyDeviceId)
            ? _owedWrites[keyDeviceId]
            : await _storage.read(key: keyDeviceId);
      } catch (_) {
        deviceId = null;
      }
    }
    await _storage.deleteAll();
    // Nothing owed survives a full reset (the device id is rewritten below).
    _owedWrites.clear();
    _owedLegacyHistoryDelete = false;
    if (_owedSignOutKeep2fa != null) {
      _owedSignOutKeep2fa = null;
      _owedSignOutAccount = null;
      await _setDurableSignOut(null);
    }
    if (deviceId != null && deviceId.isNotEmpty) {
      await _change(keyDeviceId, deviceId);
    }
    await _deleteLegacyHistory();
  }

  /// Reads [key]; null only when the item is really not stored, otherwise
  /// a [SecureStorageReadException].
  ///
  /// flutter_secure_storage 9.2.x on iOS answers `read` with null for an
  /// item it cannot read (keychain locked, or protected data not available
  /// yet when the app returns to the foreground): the first query fails with
  /// errSecInteractionNotAllowed, `read` retries with
  /// kSecAttrSynchronizable=true, that query finds nothing and "not found"
  /// is returned. So a null is confirmed with `containsKey` (which reports
  /// the error, or finds the item) and, on iOS, with
  /// `UIApplication.isProtectedDataAvailable`. A value still owed to the
  /// keychain wins over what the keychain holds.
  Future<String?> _readRequired(String key) async {
    await _settle();
    final (owed, value) = _owed(key);
    if (owed) return value;
    return _readVerified(key);
  }

  /// A read of a key whose absence is harmless (history, remember tokens).
  Future<String?> _readOptional(String key) async {
    await _settle();
    final (owed, value) = _owed(key);
    if (owed) return value;
    return _storage.read(key: key);
  }

  Future<String?> _readVerified(String key) async {
    final String? value;
    final bool exists;
    try {
      value = await _storage.read(key: key);
      if (value != null) return value;
      exists = await _storage.containsKey(key: key);
    } catch (e) {
      throw SecureStorageReadException(e);
    }
    if (exists) {
      throw SecureStorageReadException('$key is stored but unreadable');
    }
    bool? available;
    try {
      available = await _storage.isCupertinoProtectedDataAvailable();
    } catch (_) {
      available = null; // not an Apple platform / plugin without it
    }
    if (available == false) {
      throw const SecureStorageReadException('protected data unavailable');
    }
    return null;
  }

  // ── Write guard ──

  /// `(true, value)` when a change of [key] is still owed to the keychain
  /// (value null = deleted), else `(false, null)`.
  (bool, String?) _owed(String key) {
    if (_owedWrites.containsKey(key)) return (true, _owedWrites[key]);
    final keep2fa = _owedSignOutKeep2fa;
    if (keep2fa != null && _signOutDeletes(key, keep2fa)) return (true, null);
    return (false, null);
  }

  static bool _signOutDeletes(String key, bool keepTwoFactorRemember) =>
      key == keySession ||
      key == keyEncryptedUserKey ||
      key == keyBiometricStorageKey ||
      key.startsWith(historyKeyPrefix) ||
      (!keepTwoFactorRemember && key.startsWith(twoFactorRememberPrefix));

  /// Writes (or deletes, [value] null) [key] now when the keychain can take
  /// it, else owes it. A write that fails anyway is owed as well — the
  /// plugin may already have deleted the old item — and the error is
  /// rethrown for callers that report it.
  Future<void> _change(String key, String? value) async {
    if (await _readyToWrite()) {
      try {
        if (value == null) {
          await _storage.delete(key: key);
        } else {
          await _storage.write(key: key, value: value);
        }
        return;
      } catch (_) {
        _owe(key, value);
        rethrow;
      }
    }
    _owe(key, value);
  }

  void _owe(String key, String? value) {
    _owedWrites.remove(key); // newest last: applied in order
    _owedWrites[key] = value;
    _watchAvailability();
  }

  /// True when nothing is owed any more and (iOS) protected data is
  /// available: a change may go straight to the keychain.
  Future<bool> _readyToWrite() async {
    await _settle();
    if (hasPendingChanges) return false; // keep the order
    return !_guardWrites || await _available();
  }

  Future<void> _oweSignOut(
      bool keepTwoFactorRemember, UserSession? account) async {
    // Two owed sign-outs: the more thorough one wins.
    _owedSignOutKeep2fa =
        (_owedSignOutKeep2fa ?? true) && keepTwoFactorRemember;
    _owedSignOutAccount = account ?? _owedSignOutAccount;
    _signOutGeneration++;
    await _setDurableSignOut(_owedSignOutKeep2fa);
    _watchAvailability();
  }

  Future<bool> _available() async {
    try {
      return await _storage.isCupertinoProtectedDataAvailable() ?? true;
    } catch (_) {
      return true; // cannot tell: behave as before the guard
    }
  }

  /// Loads a sign-out owed by an earlier run (once), then applies whatever
  /// is owed if the keychain can take it. Never throws.
  Future<void> _settle() async {
    await (_durableLoad ??= _loadDurableSignOut());
    if (!hasPendingChanges) return;
    await (_flushing ??= _flush().whenComplete(() => _flushing = null));
  }

  Future<void> _flush() async {
    if (!_guardWrites || await _available()) {
      try {
        final keep2fa = _owedSignOutKeep2fa;
        if (keep2fa != null) {
          final generation = _signOutGeneration;
          await _clearSessionNow(keep2fa, _owedSignOutAccount);
          if (generation == _signOutGeneration) {
            _owedSignOutKeep2fa = null;
            _owedSignOutAccount = null;
            await _setDurableSignOut(null);
          }
        }
        if (_owedLegacyHistoryDelete) {
          await _deleteLegacyHistory();
          _owedLegacyHistoryDelete = false;
        }
        for (final MapEntry(:key, :value) in _owedWrites.entries.toList()) {
          if (value == null) {
            await _storage.delete(key: key);
          } else {
            await _storage.write(key: key, value: value);
          }
          // Unless it changed meanwhile.
          if (_owedWrites.containsKey(key) && _owedWrites[key] == value) {
            _owedWrites.remove(key);
          }
        }
      } catch (_) {
        // Still owed: retried on the next access, resume or availability.
      }
    }
    if (hasPendingChanges) {
      _watchAvailability();
    } else {
      _stopWatchingAvailability();
    }
  }

  void _watchAvailability() {
    if (!_guardWrites || _availability != null) return;
    final Stream<bool>? events;
    try {
      events = _storage.onCupertinoProtectedDataAvailabilityChanged;
    } catch (_) {
      return;
    }
    _availability = events?.listen(
      (available) {
        if (available) unawaited(_settle());
      },
      onError: (Object _) {},
    );
  }

  void _stopWatchingAvailability() {
    unawaited(_availability?.cancel());
    _availability = null;
  }

  Future<void> _loadDurableSignOut() async {
    try {
      final stored = (await _preferences()).getString(prefsPendingSignOut);
      if (stored == null) return;
      _owedSignOutKeep2fa =
          (_owedSignOutKeep2fa ?? true) && stored == _signOutKeep2faValue;
    } catch (_) {
      // No preferences (tests, early start): nothing owed from before.
    }
  }

  static const _signOutKeep2faValue = 'keep_2fa';

  Future<void> _setDurableSignOut(bool? keepTwoFactorRemember) async {
    try {
      final prefs = await _preferences();
      if (keepTwoFactorRemember == null) {
        await prefs.remove(prefsPendingSignOut);
      } else {
        await prefs.setString(
          prefsPendingSignOut,
          keepTwoFactorRemember ? _signOutKeep2faValue : 'all',
        );
      }
    } catch (_) {
      // Best effort: the in-memory record still applies in this run.
    }
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
