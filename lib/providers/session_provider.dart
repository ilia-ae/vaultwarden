import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pointycastle/digests/sha256.dart';

import '../app.dart';
import '../demo_fixtures.dart';
import '../models/cipher_string.dart';
import '../models/kdf_params.dart';
import '../models/server_environment.dart';
import '../models/token_response.dart';
import '../models/user_session.dart';
import '../services/crypto_service.dart';
import '../services/secure_storage_service.dart';
import '../services/vault_api.dart';
import '../utils/constants.dart';
import 'auth_requests_provider.dart';
import 'service_providers.dart';

/// Holds the decrypted UserKey in memory after biometric unlock.
/// Null means locked / not set up.
final userKeyProvider = StateProvider<Uint8List?>((_) => null);

/// Why the app went back to the setup screen without the user logging out.
enum SessionEndNotice {
  /// The server rejected the refresh token (password change, "deauthorize
  /// sessions", long inactivity…) — F11.
  sessionEnded,

  /// The notifications hub sent LogOut (type 11: password/KDF change, key
  /// rotation, admin deauthorisation) — A9.
  signedOutByServer,
}

/// Set when the server ended the session; cleared by the next successful
/// setup. The app shows it once as a SnackBar; the setup screen may also
/// show it inline.
final sessionEndNoticeProvider = StateProvider<SessionEndNotice?>((_) => null);

/// Login progress (the UI localises these; [SessionNotifier.setup] also
/// reports an English status string for older callers).
enum SetupStep {
  serverParameters,
  derivingKey,
  authenticating,
  decryptingKey,
  securingKeys,
}

/// Bitwarden TwoFactorProviderType "Remember" (stored remember token).
const kTwoFactorProviderRemember = 5;

/// Manages session lifecycle: setup, biometric unlock, logout.
final sessionProvider =
    AsyncNotifierProvider<SessionNotifier, UserSession?>(SessionNotifier.new);

/// Identity of the signed-in account (`<serverUrl>|<email>`), null when
/// signed out. Select this when only account changes matter — token
/// refreshes replace the session but keep the account.
String? sessionAccountKey(AsyncValue<UserSession?> session) {
  final s = session.valueOrNull;
  if (s == null) return null;
  return '${s.serverUrl}|${s.email.trim().toLowerCase()}';
}

bool _sameAccount(UserSession a, UserSession b) =>
    a.serverUrl == b.serverUrl &&
    a.email.trim().toLowerCase() == b.email.trim().toLowerCase();

class SessionNotifier extends AsyncNotifier<UserSession?> {
  _PendingLogin? _pendingLogin;
  Future<void>? _clearing;
  bool _endingSession = false;

  @override
  Future<UserSession?> build() async {
    // Compile-time demo: hand back a fake session so the app routes straight
    // into the (fixture-backed) RequestsScreen — no storage, no API. (The
    // runtime demo overrides this provider in its own container; the real
    // container keeps reading the real session.)
    if (isDemoMode) return demoSession();
    _listenToServices();
    final storage = ref.read(secureStorageProvider);
    // Throws SecureStorageReadException when the keychain itself fails —
    // the app then shows a retry screen instead of the setup screen (R4).
    final session = await storage.loadSession();
    if (session != null) {
      final api = ref.read(apiServiceProvider);
      final live = api.session;
      if (live == null || !_sameAccount(live, session)) {
        api.configure(session.serverUrl, session);
      }
    }
    return session;
  }

  void _listenToServices() {
    final api = ref.read(apiServiceProvider);
    final hub = ref.read(notificationServiceProvider);
    final subs = <StreamSubscription<Object?>>[
      api.onSessionRefreshed.listen(_onSessionRefreshed),
      api.onSessionEnded
          .listen((_) => endSession(SessionEndNotice.sessionEnded)),
      // A9: forced re-login, except for Reason 0 (KDF change) — the session
      // and the user key stay valid then (see kLogOutReasonKdfChange).
      hub.onLogOut
          .where((e) => e.logOutReason != kLogOutReasonKdfChange)
          .listen((_) => endSession(SessionEndNotice.signedOutByServer)),
    ];
    ref.onDispose(() {
      for (final s in subs) {
        s.cancel();
      }
    });
  }

  /// A5: every refreshed session goes into this provider (persisted) and to
  /// the hub. Late events for a session that was replaced or logged out are
  /// ignored, so they can never write an old session back.
  void _onSessionRefreshed(UserSession refreshed) {
    if (demoActive || _endingSession) return;
    final live = ref.read(apiServiceProvider).session;
    if (live == null ||
        live.accessToken != refreshed.accessToken ||
        live.refreshToken != refreshed.refreshToken) {
      return;
    }
    final current = state.valueOrNull;
    if (current == null || !_sameAccount(current, refreshed)) return;
    // The API persists it too; this retries a keychain write that failed
    // there. No await before the write, so a logout cannot slip in between.
    unawaited(ref
        .read(secureStorageProvider)
        .saveSession(refreshed)
        .catchError((Object _) {}));
    state = AsyncData(refreshed);
    ref.read(notificationServiceProvider).updateToken(refreshed.accessToken);
  }

  /// Full first-time setup: prelogin → derive keys → login → store.
  /// Returns the decrypted UserKey (64 bytes).
  ///
  /// Throws typed [ApiException]s: [TwoFactorRequiredException] (re-call
  /// with [twoFactorToken] + [twoFactorProvider]),
  /// [NewDeviceVerificationRequiredException] (re-call with [newDeviceOtp]),
  /// [InvalidTwoFactorCodeException], [InvalidCredentialsException], …
  ///
  /// Without an explicit [twoFactorToken], a stored "remember this device"
  /// token for this server + email is tried first (provider 5, A6). When the
  /// server still wants 2FA, the stored token is deleted and the
  /// [TwoFactorRequiredException] is surfaced — it is never retried.
  ///
  /// Derived keys are cached for 10 minutes for the same server, email and
  /// password, so the 2FA/new-device retry does not run the KDF again.
  Future<Uint8List> setup({
    required String serverUrl,
    required String email,
    required String masterPassword,
    required void Function(String status) onProgress,
    void Function(SetupStep step)? onStep,
    String? twoFactorToken,
    int? twoFactorProvider,
    bool rememberTwoFactor = true,
    String? newDeviceOtp,
  }) async {
    _refuseInDemo();
    final crypto = ref.read(cryptoServiceProvider);
    final api = ref.read(apiServiceProvider);
    final storage = ref.read(secureStorageProvider);
    final baseUrl = ServerEnvironment.fromUrl(serverUrl).baseUrl;
    final account = email.trim();

    void report(SetupStep step, String status) {
      onStep?.call(step);
      onProgress(status);
    }

    // A logout's keychain cleanup must not delete what we are about to write.
    await _clearing;
    // The unscoped history of older builds belongs to whoever was signed in
    // then — never to this new sign-in (F13).
    await storage.deleteLegacyHistory();

    // 1–2. KDF params + master key / server hash (cached for retries).
    report(SetupStep.serverParameters, 'Getting server parameters...');
    final pending = await _loginKeys(
      baseUrl,
      account,
      masterPassword,
      onDerive: () => report(SetupStep.derivingKey, 'Deriving master key...'),
    );

    // 3. Login (may throw TwoFactorRequiredException etc.)
    report(SetupStep.authenticating, 'Authenticating...');
    final deviceId = await storage.getOrCreateDeviceId();
    final raw = await _passwordGrant(
      api: api,
      storage: storage,
      baseUrl: baseUrl,
      email: account,
      hashB64: pending.keys.masterPasswordHashB64,
      deviceId: deviceId,
      twoFactorToken: twoFactorToken,
      twoFactorProvider: twoFactorProvider,
      rememberTwoFactor: rememberTwoFactor,
      newDeviceOtp: newDeviceOtp,
    );
    final token = TokenResponse.fromJson(raw);
    final refreshToken = token.refreshToken;
    if (refreshToken == null) {
      throw const FormatException('Token response without refresh_token');
    }

    // 4. Decrypt the protected user key (A8: missing key → typed error).
    report(SetupStep.decryptingKey, 'Decrypting encryption key...');
    final protectedKey = CipherString.parse(token.requireProtectedUserKey());
    final userKey = await _decryptUserKey(
      crypto,
      pending,
      token,
      account,
      masterPassword,
      protectedKey,
    );
    _wipePendingLogin();

    final rememberToken = token.twoFactorToken;
    if (rememberToken != null) {
      try {
        await storage.saveTwoFactorRememberToken(
          serverUrl: baseUrl,
          email: account,
          token: rememberToken,
        );
      } catch (_) {
        // Only a convenience: the next login asks for 2FA again.
      }
    }

    // 5. Encrypt userKey for biometric storage and persist everything.
    report(SetupStep.securingKeys, 'Securing keys...');
    final storageKey = _generateStorageKey();
    final encryptedUserKey = crypto.encryptSymmetric(userKey, storageKey);
    await storage.saveEncryptedUserKey(encryptedUserKey.encode());
    await storage.saveBiometricStorageKey(base64Encode(storageKey));
    storageKey.fillRange(0, storageKey.length, 0);

    final session = UserSession(
      email: account,
      serverUrl: baseUrl,
      accessToken: token.accessToken,
      refreshToken: refreshToken,
      accessTokenExpiry: token.expiryFrom(DateTime.now()),
    );
    await storage.saveSession(session);

    api.configure(baseUrl, session);

    ref.read(sessionEndNoticeProvider.notifier).state = null;
    state = AsyncData(session);
    ref.read(userKeyProvider.notifier).state = userKey;
    ref.read(isLockedProvider.notifier).state = false;

    return userKey;
  }

  /// Demo builds (screenshot DEMO_MODE, runtime tester demo) never sign in:
  /// no server, no keychain (F7).
  void _refuseInDemo() {
    if (demoActive) throw StateError('Sign-in is disabled in demo mode');
  }

  /// POST {api}/two-factor/send-email-login for the pending login (F12:
  /// bitwarden.com never e-mails the code on its own, and Vaultwarden stops
  /// doing so for current client versions).
  Future<void> sendEmailLoginCode({
    required String serverUrl,
    required String email,
    required String masterPassword,
  }) async {
    _refuseInDemo();
    final baseUrl = ServerEnvironment.fromUrl(serverUrl).baseUrl;
    final pending = await _loginKeys(baseUrl, email.trim(), masterPassword);
    final deviceId =
        await ref.read(secureStorageProvider).getOrCreateDeviceId();
    await ref.read(apiServiceProvider).sendEmailLoginCode(
          serverUrl: baseUrl,
          email: email.trim(),
          masterPasswordHashB64: pending.keys.masterPasswordHashB64,
          deviceId: deviceId,
        );
  }

  /// Asks bitwarden.com to e-mail a new new-device verification code (F6).
  Future<void> resendNewDeviceOtp({
    required String serverUrl,
    required String email,
    required String masterPassword,
  }) async {
    _refuseInDemo();
    final baseUrl = ServerEnvironment.fromUrl(serverUrl).baseUrl;
    final pending = await _loginKeys(baseUrl, email.trim(), masterPassword);
    final deviceId =
        await ref.read(secureStorageProvider).getOrCreateDeviceId();
    await ref.read(apiServiceProvider).resendNewDeviceOtp(
          serverUrl: baseUrl,
          email: email.trim(),
          masterPasswordHashB64: pending.keys.masterPasswordHashB64,
          deviceId: deviceId,
        );
  }

  /// Forget the keys cached for a pending login (the user cancelled the
  /// 2FA / new-device dialog).
  void cancelPendingLogin() => _wipePendingLogin();

  Future<_PendingLogin> _loginKeys(
    String baseUrl,
    String email,
    String masterPassword, {
    void Function()? onDerive,
  }) async {
    final cached = _pendingLogin;
    if (cached != null && cached.matches(baseUrl, email, masterPassword)) {
      return cached;
    }
    _wipePendingLogin();
    final kdf = await ref.read(apiServiceProvider).prelogin(baseUrl, email);
    onDerive?.call();
    final keys = await ref
        .read(cryptoServiceProvider)
        .deriveLoginKeys(email, masterPassword, kdf);
    final pending = _PendingLogin(
      baseUrl: baseUrl,
      email: email,
      password: masterPassword,
      kdf: kdf,
      keys: keys,
    );
    _pendingLogin = pending;
    return pending;
  }

  void _wipePendingLogin() {
    _pendingLogin?.keys.wipe();
    _pendingLogin = null;
  }

  Future<Map<String, dynamic>> _passwordGrant({
    required VaultApiService api,
    required SecureStorageService storage,
    required String baseUrl,
    required String email,
    required String hashB64,
    required String deviceId,
    required String? twoFactorToken,
    required int? twoFactorProvider,
    required bool rememberTwoFactor,
    required String? newDeviceOtp,
  }) async {
    Future<Map<String, dynamic>> grant({
      String? token,
      int? provider,
      bool remember = true,
    }) =>
        api.login(
          serverUrl: baseUrl,
          email: email,
          masterPasswordHashB64: hashB64,
          deviceId: deviceId,
          twoFactorToken: token,
          twoFactorProvider: provider,
          twoFactorRemember: remember,
          newDeviceOtp: newDeviceOtp,
        );

    if (twoFactorToken != null) {
      return grant(
        token: twoFactorToken,
        provider: twoFactorProvider,
        remember: rememberTwoFactor,
      );
    }

    String? remembered;
    try {
      remembered = await storage.loadTwoFactorRememberToken(
        serverUrl: baseUrl,
        email: email,
      );
    } catch (_) {
      remembered = null;
    }
    if (remembered == null || remembered.isEmpty) return grant();

    Future<void> forget() async {
      try {
        await storage.deleteTwoFactorRememberToken(
          serverUrl: baseUrl,
          email: email,
        );
      } catch (_) {
        // best effort
      }
    }

    try {
      return await grant(
        token: remembered,
        provider: kTwoFactorProviderRemember,
        remember: false,
      );
    } on TwoFactorRequiredException {
      // Expired/revoked remember token: forget it and let the user pick a
      // method. Never retried with the stored token (A6).
      await forget();
      rethrow;
    } on InvalidTwoFactorCodeException {
      // Some servers reject a stale token as a wrong code: ask once more
      // without it to get the provider list.
      await forget();
      return grant();
    }
  }

  Future<Uint8List> _decryptUserKey(
    CryptoService crypto,
    _PendingLogin pending,
    TokenResponse token,
    String email,
    String masterPassword,
    CipherString protectedKey,
  ) async {
    final unlockKdf = token.masterPasswordUnlock?.kdf;
    final sameKdf = unlockKdf == null ||
        (unlockKdf.sameKdfAs(pending.kdf) &&
            unlockKdf.saltFor(email) == pending.kdf.saltFor(email));
    if (sameKdf) {
      return crypto.decryptUserKeyWithMasterKey(
        protectedKey,
        pending.keys.masterKey,
      );
    }
    // The account's unlock data names another KDF/salt than prelogin did.
    final masterKey =
        await crypto.deriveMasterKey(email, masterPassword, unlockKdf);
    try {
      return crypto.decryptUserKeyWithMasterKey(protectedKey, masterKey);
    } finally {
      masterKey.fillRange(0, masterKey.length, 0);
    }
  }

  /// Biometric unlock: authenticate → decrypt UserKey from storage.
  /// [reason] is the localized Face ID / fingerprint prompt text.
  Future<Uint8List> unlockWithBiometrics({String? reason}) async {
    final biometric = ref.read(biometricServiceProvider);
    final storage = ref.read(secureStorageProvider);
    final crypto = ref.read(cryptoServiceProvider);

    final authenticated = reason == null
        ? await biometric.authenticate()
        : await biometric.authenticate(reason: reason);
    if (!authenticated) throw Exception('Biometric authentication failed');

    final encryptedStr = await storage.loadEncryptedUserKey();
    final storageKeyB64 = await storage.loadBiometricStorageKey();

    if (encryptedStr == null || storageKeyB64 == null) {
      throw StateError('Setup not completed');
    }

    final storageKey = base64Decode(storageKeyB64);
    final encrypted = CipherString.parse(encryptedStr);
    final userKey =
        crypto.decryptSymmetric(encrypted, Uint8List.fromList(storageKey));

    // Configure the API unless it already holds this account's (possibly
    // newer, refreshed) session.
    var session = state.valueOrNull ?? await storage.loadSession();
    if (session != null) {
      final api = ref.read(apiServiceProvider);
      final live = api.session;
      if (live != null && _sameAccount(live, session)) {
        session = live;
      } else {
        api.configure(session.serverUrl, session);
      }
      if (!identical(state.valueOrNull, session)) state = AsyncData(session);
    }

    ref.read(userKeyProvider.notifier).state = userKey;
    return userKey;
  }

  /// False when the keychain has a session but not the encrypted user key
  /// (the lock screen then offers "Log out"). Errors count as "present" —
  /// an unreadable keychain is not a missing key.
  Future<bool> hasStoredUserKey() async {
    if (demoActive) return true;
    try {
      final storage = ref.read(secureStorageProvider);
      final encrypted = await storage.loadEncryptedUserKey();
      final storageKey = await storage.loadBiometricStorageKey();
      return encrypted != null && storageKey != null;
    } catch (_) {
      return true;
    }
  }

  /// Lock: zero the UserKey in memory.
  void lock() {
    final key = ref.read(userKeyProvider);
    if (key != null) {
      key.fillRange(0, key.length, 0);
    }
    ref.read(userKeyProvider.notifier).state = null;
  }

  /// User logout (A13): deletes session, keys, history and 2FA remember
  /// tokens; keeps device_id, client certificates and preferences.
  ///
  /// In demo mode this only leaves the demo — real storage is never touched
  /// (R4).
  Future<void> logout() async {
    if (demoActive) {
      lock();
      // Runtime demo: the App swaps the demo container out and resets the
      // real one (see App); compile-time demo just shows the setup screen.
      if (demoRuntime.value) demoRuntime.value = false;
      state = const AsyncData(null);
      return;
    }
    await _signOut(keepTwoFactorRemember: false, notice: null);
  }

  /// The server ended the session (dead refresh token, F11) or signed this
  /// device out (hub LogOut, A9): stop everything and return to the setup
  /// screen with [notice]. Keeps device_id, client certificates and the 2FA
  /// remember token so the re-login is quick. Idempotent.
  Future<void> endSession(SessionEndNotice notice) async {
    if (demoActive || _endingSession) return;
    if (state.valueOrNull == null) return;
    await _signOut(keepTwoFactorRemember: true, notice: notice);
  }

  Future<void> _signOut({
    required bool keepTwoFactorRemember,
    required SessionEndNotice? notice,
  }) async {
    _endingSession = true;
    try {
      // Stop polling/realtime and forget the in-memory session BEFORE the
      // keychain is cleared, so an in-flight refresh cannot write it back.
      final account = state.valueOrNull;
      _stopRequests();
      ref.read(apiServiceProvider).reset();
      ref.read(notificationServiceProvider).reset();
      lock();
      _wipePendingLogin();
      ref.read(sessionEndNoticeProvider.notifier).state = notice;
      state = const AsyncData(null);
      _invalidateLists();

      final clearing = _clearStorage(keepTwoFactorRemember, account);
      _clearing = clearing;
      await clearing;
      if (identical(_clearing, clearing)) _clearing = null;
    } finally {
      _endingSession = false;
    }
  }

  Future<void> _clearStorage(
    bool keepTwoFactorRemember,
    UserSession? account,
  ) async {
    try {
      await ref.read(secureStorageProvider).clearSessionData(
            keepTwoFactorRemember: keepTwoFactorRemember,
            session: account,
          );
    } catch (_) {
      // Keychain unavailable: memory is already clean; a stale entry is
      // overwritten by the next setup.
    }
  }

  void _stopRequests() {
    if (ref.exists(authRequestsProvider)) {
      ref.read(authRequestsProvider.notifier).stop();
    }
  }

  /// Stops polling and realtime, forgets the in-memory server session and
  /// drops the cached request list and history (F7). Used on logout and on
  /// both runtime-demo toggles; never touches storage.
  void resetLiveState() {
    _stopRequests();
    ref.read(apiServiceProvider).reset();
    ref.read(notificationServiceProvider).reset();
    _invalidateLists();
  }

  /// Rebuilds the request list and history from scratch. Both depend on
  /// this provider, so `ref.invalidate` would count as a dependency cycle;
  /// invalidation is an imperative reset, not a dependency.
  void _invalidateLists() {
    ref.container
      ..invalidate(authRequestsProvider)
      ..invalidate(historyProvider);
  }

  /// Tester 5-tap on the setup screen: reset everything real, then flip the
  /// runtime demo on (the App hosts the demo in its own container).
  void enterRuntimeDemo() {
    resetLiveState();
    lock();
    demoRuntime.value = true;
  }

  Uint8List _generateStorageKey() {
    final rng = Random.secure();
    return Uint8List.fromList(List.generate(64, (_) => rng.nextInt(256)));
  }
}

/// Keys derived for a login that is waiting for 2FA / new-device
/// verification. The password itself is not kept, only a salted digest to
/// recognise the same input.
class _PendingLogin {
  _PendingLogin({
    required this.baseUrl,
    required String email,
    required String password,
    required this.kdf,
    required this.keys,
  })  : email = email.toLowerCase(),
        _passwordDigest = _digest(password),
        createdAt = DateTime.now();

  static const ttl = Duration(minutes: 10);
  static final Uint8List _salt = Uint8List.fromList(
      List.generate(32, (_) => Random.secure().nextInt(256)));

  final String baseUrl;
  final String email;
  final Uint8List _passwordDigest;
  final KdfParams kdf;
  final LoginKeys keys;
  final DateTime createdAt;

  static Uint8List _digest(String password) => SHA256Digest()
      .process(Uint8List.fromList([..._salt, ...utf8.encode(password)]));

  bool matches(String baseUrl, String email, String password) {
    if (this.baseUrl != baseUrl || this.email != email.toLowerCase()) {
      return false;
    }
    if (DateTime.now().difference(createdAt) > ttl) return false;
    final d = _digest(password);
    var diff = 0;
    for (var i = 0; i < d.length; i++) {
      diff |= d[i] ^ _passwordDigest[i];
    }
    return diff == 0;
  }
}
