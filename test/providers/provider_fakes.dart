import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_approver/app.dart';
import 'package:vault_approver/models/auth_request.dart';
import 'package:vault_approver/models/kdf_params.dart';
import 'package:vault_approver/models/server_environment.dart';
import 'package:vault_approver/models/user_session.dart';
import 'package:vault_approver/providers/service_providers.dart';
import 'package:vault_approver/providers/session_provider.dart';
import 'package:vault_approver/services/crypto_service.dart';
import 'package:vault_approver/services/notification_service.dart';
import 'package:vault_approver/services/secure_storage_service.dart';
import 'package:vault_approver/services/settings_service.dart';
import 'package:vault_approver/services/vault_api.dart';

import '../services/rsa_fixture.dart';

const kServer = 'https://vault.example.com';
const kEmail = 'user@example.com';
const kPassword = 'correct horse battery staple';
const kPbkdf2 = KdfParams(kdfType: 0, iterations: 5000);

UserSession testSession({
  String accessToken = 'at-1',
  String refreshToken = 'rt-1',
  String serverUrl = kServer,
  String email = kEmail,
}) =>
    UserSession(
      email: email,
      serverUrl: serverUrl,
      accessToken: accessToken,
      refreshToken: refreshToken,
      accessTokenExpiry: DateTime.now().add(const Duration(hours: 2)),
    );

AuthRequest testRequest(
  String id, {
  String ip = '203.0.113.9',
  Duration age = const Duration(seconds: 10),
  String? fingerprint = 'alpha-bravo-charlie-delta-echo',
}) =>
    AuthRequest(
      id: id,
      publicKey: fixtureRsaSpkiB64,
      requestDeviceType: 'Chrome',
      requestIpAddress: ip,
      creationDate: DateTime.now().subtract(age),
      fingerprint: fingerprint,
    );

/// Records every call; no network.
class FakeVaultApi extends Fake implements VaultApiService {
  final _refreshed = StreamController<UserSession>.broadcast();
  final _ended = StreamController<SessionEndedException>.broadcast();

  UserSession? _session;
  final calls = <String>[];
  int resets = 0;
  int pendingCalls = 0;
  List<AuthRequest> pending = [];
  Object? pendingError;
  KdfParams kdf = kPbkdf2;
  int preloginCalls = 0;
  final loginCalls = <Map<String, Object?>>[];

  /// Answers a password grant (throw to simulate server errors).
  Map<String, dynamic> Function(Map<String, Object?> call)? onLogin;

  /// Calls that reach the server (everything except bookkeeping).
  List<String> get serverCalls =>
      calls.where((c) => c != 'reset' && c != 'configure').toList();

  @override
  UserSession? get session => _session;

  @override
  bool get isSessionEnded => false;

  @override
  Stream<UserSession> get onSessionRefreshed => _refreshed.stream;

  @override
  Stream<SessionEndedException> get onSessionEnded => _ended.stream;

  @override
  void configure(String serverUrl, UserSession session) {
    calls.add('configure');
    _session = session;
  }

  @override
  void updateSession(UserSession session) => _session = session;

  @override
  void reset() {
    calls.add('reset');
    resets++;
    _session = null;
  }

  @override
  Future<String?> getValidAccessToken({bool forceRefresh = false}) async =>
      _session?.accessToken;

  /// Server URLs prelogin was called with.
  final preloginUrls = <String>[];

  @override
  Future<KdfParams> prelogin(String serverUrl, String email) async {
    calls.add('prelogin');
    preloginCalls++;
    preloginUrls.add(serverUrl);
    return kdf;
  }

  /// send-email-login calls (server URLs); throw [emailCodeError] if set.
  final emailCodeRequests = <String>[];
  Object? emailCodeError;

  @override
  Future<void> sendEmailLoginCode({
    required String serverUrl,
    required String email,
    required String masterPasswordHashB64,
    required String deviceId,
  }) async {
    calls.add('sendEmailLoginCode');
    emailCodeRequests.add(serverUrl);
    final error = emailCodeError;
    if (error != null) throw error;
  }

  /// resend-new-device-otp calls (device ids).
  final newDeviceOtpResends = <String>[];

  @override
  Future<void> resendNewDeviceOtp({
    required String serverUrl,
    required String email,
    required String masterPasswordHashB64,
    required String deviceId,
  }) async {
    calls.add('resendNewDeviceOtp');
    newDeviceOtpResends.add(deviceId);
  }

  @override
  Future<Map<String, dynamic>> login({
    required String serverUrl,
    required String email,
    required String masterPasswordHashB64,
    required String deviceId,
    String? twoFactorToken,
    int? twoFactorProvider,
    bool twoFactorRemember = true,
    String? newDeviceOtp,
  }) async {
    calls.add('login');
    final call = <String, Object?>{
      'serverUrl': serverUrl,
      'email': email,
      'hash': masterPasswordHashB64,
      'deviceId': deviceId,
      'twoFactorToken': twoFactorToken,
      'twoFactorProvider': twoFactorProvider,
      'twoFactorRemember': twoFactorRemember,
      'newDeviceOtp': newDeviceOtp,
    };
    loginCalls.add(call);
    return onLogin!(call);
  }

  @override
  Future<List<AuthRequest>> getPendingRequests({
    bool includeExpired = false,
  }) async {
    calls.add('pending');
    pendingCalls++;
    if (_session == null) throw StateError('Not authenticated');
    final error = pendingError;
    if (error != null) throw error;
    return AuthRequest.selectPending(pending, includeExpired: includeExpired);
  }

  @override
  Future<void> respondToAuthRequest({
    required String requestId,
    required bool approved,
    String? encryptedKey,
    required String deviceId,
  }) async {
    calls.add('respond:$requestId:$approved');
    if (_session == null) throw StateError('Not authenticated');
    pending = [...pending]..removeWhere((r) => r.id == requestId);
  }

  @override
  void dispose() {}

  /// The interceptor refreshed the token.
  void simulateRefresh(UserSession s) {
    _session = s;
    _refreshed.add(s);
  }

  /// The server rejected the refresh token.
  void simulateSessionEnded() => _ended.add(const SessionEndedException(
      reason: SessionEndReason.refreshTokenRejected));
}

/// Records connects/pauses/resets; emits hub events on demand.
class FakeHub extends Fake implements NotificationService {
  final _events = StreamController<HubEvent>.broadcast();
  final connects = <ServerEnvironment>[];
  final tokens = <String>[];
  int resets = 0;
  int pauses = 0;
  int resumes = 0;

  @override
  Stream<HubEvent> get events => _events.stream;

  @override
  Stream<HubEvent> get onLogOut => _events.stream.where((e) => e.isLogOut);

  @override
  Stream<int> get onNotification => _events.stream.map((e) => e.type);

  @override
  Future<void> connectEnvironment(
    ServerEnvironment env, {
    HubTokenProvider? tokenProvider,
  }) async {
    connects.add(env);
  }

  @override
  Future<void> connect(String serverUrl, String accessToken) async {
    connects.add(ServerEnvironment.fromUrl(serverUrl));
  }

  @override
  void updateToken(String newAccessToken) => tokens.add(newAccessToken);

  @override
  void pause() => pauses++;

  @override
  void resume() => resumes++;

  @override
  void disconnect() {}

  @override
  void reset() => resets++;

  @override
  void dispose() {}

  void emit(int type, {Map<String, Object?> payload = const {}}) =>
      _events.add(HubEvent(type: type, payload: payload));
}

/// Keychain that fails to read the session (device locked, keystore reset).
class ThrowingSessionStorage extends SecureStorageService {
  ThrowingSessionStorage() : super();

  @override
  Future<UserSession?> loadSession() async =>
      throw const SecureStorageReadException('keychain locked');
}

/// A root container with fake services and in-memory keychain / prefs.
class Harness {
  Harness._(
      this.container, this.api, this.hub, this.storage, this.raw, this.crypto);

  final ProviderContainer container;
  final FakeVaultApi api;
  final FakeHub hub;
  final SecureStorageService storage;
  final FlutterSecureStorage raw;
  final CryptoService crypto;

  /// The user key of the seeded account (see [seedAccount]).
  static final userKey =
      Uint8List.fromList(List.generate(64, (i) => (i * 7 + 3) & 0xff));

  static Future<Harness> create({
    SecureStorageService? storage,
    Map<String, Object> prefs = const {},
    List<Override> overrides = const [],
  }) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(prefs);
    final settings = SettingsService(await SharedPreferences.getInstance());
    final api = FakeVaultApi();
    final hub = FakeHub();
    final store = storage ?? SecureStorageService();
    final crypto = CryptoService(runKdfInIsolate: false);
    final container = ProviderContainer(overrides: [
      settingsServiceProvider.overrideWithValue(settings),
      apiServiceProvider.overrideWithValue(api),
      notificationServiceProvider.overrideWithValue(hub),
      secureStorageProvider.overrideWithValue(store),
      cryptoServiceProvider.overrideWithValue(crypto),
      ...overrides,
    ]);
    return Harness._(
        container, api, hub, store, const FlutterSecureStorage(), crypto);
  }

  /// Stores a signed-in account as a previous run would have left it, plus
  /// a device id and a client certificate.
  Future<void> seedAccount({UserSession? session}) async {
    final storageKey =
        Uint8List.fromList(List.generate(64, (i) => (i * 13 + 1) & 0xff));
    await storage.saveEncryptedUserKey(
        crypto.encryptSymmetric(userKey, storageKey).encode());
    await storage.saveBiometricStorageKey(base64Encode(storageKey));
    await storage.saveSession(session ?? testSession());
    await storage.getOrCreateDeviceId();
    await raw.write(key: 'client_cert|$kServer', value: '{"p12":""}');
    await raw.write(key: 'client_ca|$kServer', value: 'pem');
  }

  /// Seeds an account, loads the session and "unlocks" (user key in
  /// memory) like a biometric unlock would.
  Future<UserSession> signIn({UserSession? session}) async {
    await seedAccount(session: session);
    final s = await container.read(sessionProvider.future);
    container.read(userKeyProvider.notifier).state =
        Uint8List.fromList(userKey);
    container.read(isLockedProvider.notifier).state = false;
    return s!;
  }

  /// A protected user key (type 2) for [email]/[password] with [kdf].
  Future<String> protectedUserKey({
    String email = kEmail,
    String password = kPassword,
    KdfParams kdf = kPbkdf2,
  }) async {
    final masterKey = await crypto.deriveMasterKey(email, password, kdf);
    final stretched = crypto.stretchMasterKey(masterKey);
    return crypto.encryptSymmetric(userKey, stretched).encode();
  }

  Future<Map<String, String>> keychain() => raw.readAll();

  void dispose() => container.dispose();
}
