import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

import '../models/api_error.dart';
import '../models/auth_request.dart';
import '../models/json_util.dart';
import '../models/kdf_params.dart';
import '../models/server_environment.dart';
import '../models/token_response.dart';
import '../models/user_session.dart';
import '../utils/constants.dart';
import 'client_cert_service.dart';
import 'crypto_service.dart';
import 'secure_storage_service.dart';

export '../models/api_error.dart';

// RequestOptions.extra keys.
const _kAuth = 'va.auth'; // needs a bearer token
const _kRetried = 'va.retried'; // already retried once after a 401
const _kRefreshFailed = 'va.refreshFailed'; // pre-emptive refresh rejected
const _kToken = 'va.token'; // access token this attempt was sent with
const _kCert = 'va.cert'; // a client certificate was configured

/// Thrown internally when the token endpoint rejected a refresh with
/// something other than `invalid_grant` (never escapes this file).
class _RefreshRejected implements Exception {
  const _RefreshRejected();
}

/// REST client for Bitwarden / Vaultwarden.
///
/// * Every request carries `Bitwarden-Client-Name`, `Bitwarden-Client-Version`
///   and `Device-Type` (F2).
/// * URLs come from a [ServerEnvironment] (cloud `api.`/`identity.` hosts or
///   one self-hosted base URL, F16).
/// * Errors are typed ([ApiException] subclasses, F9); network failures
///   without a response stay `DioException`s, mTLS handshake failures become
///   [ClientCertificateRequiredException] (F1).
/// * Token refresh is single-flight; a request is retried at most once after
///   a 401; a dead refresh token ends the session with
///   [SessionEndedException] (also emitted on [onSessionEnded]) and all
///   further authenticated calls fail fast without network traffic (F11).
/// * Client certificates from [ClientCertService] are applied per origin; the
///   HTTP client is rebuilt automatically when a certificate changes (F1).
class VaultApiService {
  VaultApiService(
    this._storage, {
    ClientCertService? clientCerts,
    CryptoService? crypto,
    HttpClientAdapter? httpClientAdapter,
    String? deviceType,
  })  : _certs = clientCerts ?? ClientCertService.instance,
        _crypto = crypto ?? CryptoService(),
        _adapterOverride = httpClientAdapter,
        deviceType = deviceType ?? bitwardenDeviceType() {
    _dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: defaultHeaders(this.deviceType),
      // dart:io would follow a GET redirect inside the same HttpClient, i.e.
      // with this origin's client certificate and extra CA. Bitwarden APIs
      // never redirect, so a 3xx is reported instead.
      followRedirects: false,
    ));
    final adapter = _adapterOverride;
    if (adapter != null) {
      _dio.httpClientAdapter = adapter;
    } else {
      _dio.httpClientAdapter = _transport = _PerOriginAdapter();
    }
    _dio.interceptors.add(_ApiInterceptor(this));
  }

  final SecureStorageService _storage;
  final ClientCertService _certs;
  final CryptoService _crypto;
  final HttpClientAdapter? _adapterOverride;

  /// Bitwarden DeviceType sent in `Device-Type` and the token form.
  final String deviceType;

  late final Dio _dio;

  ServerEnvironment? _env;
  UserSession? _session;
  int _sessionGeneration = 0;
  SessionEndedException? _sessionEnded;
  String? _endedRefreshToken;
  Future<UserSession>? _refreshInFlight;

  /// An access token the server refused with 401 right after it was issued
  /// or retried (see `_ApiInterceptor.onError`).
  String? _refusedFreshToken;

  bool? _pendingEndpointSupported;
  Duration? _clockOffset;
  Duration? _nowOffset;
  bool _nowOffsetAttempted = false;

  /// Null when a test adapter was injected.
  _PerOriginAdapter? _transport;

  final _sessionRefreshed = StreamController<UserSession>.broadcast();
  final _sessionEndedEvents =
      StreamController<SessionEndedException>.broadcast();

  /// Headers sent with every request (F2).
  static Map<String, String> defaultHeaders(String deviceType) => {
        'Accept': 'application/json',
        'Bitwarden-Client-Name': kBitwardenClientName,
        'Bitwarden-Client-Version': kBitwardenClientVersion,
        'Device-Type': deviceType,
      };

  // ── State ──

  ServerEnvironment? get environment => _env;
  UserSession? get session => _session;

  /// True after the server ended the session (until a new session with a
  /// different refresh token is configured).
  bool get isSessionEnded => _sessionEnded != null;

  /// `serverNow − localNow` from the last list response (HTTP `Date`) or
  /// `GET /api/now`.
  Duration get serverClockOffset => _clockOffset ?? Duration.zero;

  /// Emits the updated session after every successful token refresh (the
  /// state layer persists it and pushes the token to the hub).
  Stream<UserSession> get onSessionRefreshed => _sessionRefreshed.stream;

  /// Emits once when the server ends the session (dead refresh token, or a
  /// failed refresh followed by a 401).
  Stream<SessionEndedException> get onSessionEnded =>
      _sessionEndedEvents.stream;

  /// Sets the deployment (from [serverUrl]) and the active session.
  void configure(String serverUrl, UserSession session) {
    final env = ServerEnvironment.fromUrl(serverUrl);
    if (env != _env) _resetServerState();
    _env = env;
    _setSession(session, newGeneration: true);
  }

  /// Replaces the session (e.g. after a refresh done elsewhere).
  void updateSession(UserSession session) {
    final previous = _session;
    final sameAccount = previous != null &&
        previous.email == session.email &&
        previous.serverUrl == session.serverUrl;
    if (_env == null || !sameAccount) {
      final env = ServerEnvironment.fromUrl(session.serverUrl);
      if (env != _env) _resetServerState();
      _env = env;
    }
    _setSession(session, newGeneration: !sameAccount);
  }

  /// Forgets session and server (logout, entering demo). Call BEFORE
  /// clearing secure storage so an in-flight refresh cannot write the old
  /// session back.
  void reset() {
    _session = null;
    _env = null;
    _sessionGeneration++;
    _sessionEnded = null;
    _endedRefreshToken = null;
    _refreshInFlight = null;
    _refusedFreshToken = null;
    _resetServerState();
  }

  void _setSession(UserSession session, {required bool newGeneration}) {
    if (newGeneration) {
      _sessionGeneration++;
      _refreshInFlight = null;
    }
    if (_sessionEnded != null && session.refreshToken != _endedRefreshToken) {
      _sessionEnded = null;
      _endedRefreshToken = null;
    }
    _session = session;
  }

  void _resetServerState() {
    _pendingEndpointSupported = null;
    _clockOffset = null;
    _nowOffset = null;
    _nowOffsetAttempted = false;
  }

  /// A currently valid access token (refreshing first when it expires within
  /// a minute, or always with [forceRefresh]). Null without a session.
  /// Throws [SessionEndedException] once the session is dead. Meant as the
  /// notifications hub's token provider.
  Future<String?> getValidAccessToken({bool forceRefresh = false}) async {
    final ended = _sessionEnded;
    if (ended != null) throw ended;
    final s = _session;
    if (s == null) return null;
    if (!forceRefresh && !s.expiresWithin(const Duration(minutes: 1))) {
      return s.accessToken;
    }
    try {
      return (await _refreshSession()).accessToken;
    } on SessionEndedException {
      rethrow;
    } on _RefreshRejected {
      // The hub rejected the token (forceRefresh) and refresh failed too.
      if (forceRefresh) {
        throw _endSession(SessionEndReason.unauthorizedAfterRefreshFailure);
      }
      return _session?.accessToken;
    } catch (_) {
      return _session?.accessToken; // transient: let the caller back off
    }
  }

  // ── Identity endpoints ──

  /// POST {identity}/accounts/prelogin → KDF params (+ server salt, F14/F17).
  Future<KdfParams> prelogin(String serverUrl, String email) {
    final env = ServerEnvironment.fromUrl(serverUrl);
    return _guard(() async {
      final response = await _dio.post<dynamic>(
        '${env.identityUrl}/accounts/prelogin',
        data: {'email': email.trim()},
      );
      final data = asJsonMap(response.data);
      if (data == null) {
        throw const FormatException('Invalid prelogin response');
      }
      return KdfParams.fromJson(data);
    });
  }

  /// POST {identity}/connect/token (password grant).
  ///
  /// Returns the raw JSON (parse with [TokenResponse.fromJson]). Throws
  /// typed errors: [TwoFactorRequiredException],
  /// [InvalidTwoFactorCodeException], [NewDeviceVerificationRequiredException],
  /// [InvalidNewDeviceOtpException], [InvalidCredentialsException],
  /// [RateLimitedException], [ClientVersionRejectedException],
  /// [ClientCertificateRequiredException], [ServerException].
  ///
  /// 2FA: pass [twoFactorProvider] + [twoFactorToken] (provider 5 with a
  /// stored remember token). New-device verification: resend the identical
  /// request (same [deviceId]) with [newDeviceOtp].
  Future<Map<String, dynamic>> login({
    required String serverUrl,
    required String email,
    required String masterPasswordHashB64,
    required String deviceId,
    String? twoFactorToken,
    int? twoFactorProvider,
    bool twoFactorRemember = true,
    String? newDeviceOtp,
  }) {
    final env = ServerEnvironment.fromUrl(serverUrl);
    final data = <String, String>{
      'grant_type': 'password',
      'username': email.trim(),
      'password': masterPasswordHashB64,
      'scope': 'api offline_access',
      'client_id': 'mobile',
      'deviceType': deviceType,
      'deviceIdentifier': deviceId,
      'deviceName': 'Vault Approver',
    };
    if (twoFactorToken != null) {
      data['twoFactorToken'] = twoFactorToken;
      data['twoFactorProvider'] = '${twoFactorProvider ?? 0}';
      data['twoFactorRemember'] = twoFactorRemember ? '1' : '0';
    }
    if (newDeviceOtp != null && newDeviceOtp.trim().isNotEmpty) {
      data['newDeviceOtp'] = newDeviceOtp.trim();
    }
    return _guard(() async {
      final response = await _dio.post<dynamic>(
        '${env.identityUrl}/connect/token',
        data: data,
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final json = asJsonMap(response.data);
      if (json == null) throw const FormatException('Invalid token response');
      return json;
    });
  }

  /// POST {api}/two-factor/send-email-login — asks the server to e-mail a
  /// 2FA code (bitwarden.com never sends it on its own; Vaultwarden stops
  /// auto-sending once the client version is ≥ 2025.5.0).
  Future<void> sendEmailLoginCode({
    required String serverUrl,
    required String email,
    required String masterPasswordHashB64,
    required String deviceId,
  }) {
    final env = ServerEnvironment.fromUrl(serverUrl);
    return _guard(() async {
      await _dio.post<dynamic>(
        '${env.apiUrl}/two-factor/send-email-login',
        data: {
          'email': email.trim(),
          'masterPasswordHash': masterPasswordHashB64,
          'deviceIdentifier': deviceId,
        },
      );
    });
  }

  /// POST {api}/accounts/resend-new-device-otp (bitwarden.com new-device
  /// verification). The code is bound to [deviceId] (`Device-Identifier`).
  Future<void> resendNewDeviceOtp({
    required String serverUrl,
    required String email,
    required String masterPasswordHashB64,
    required String deviceId,
  }) {
    final env = ServerEnvironment.fromUrl(serverUrl);
    return _guard(() async {
      await _dio.post<dynamic>(
        '${env.apiUrl}/accounts/resend-new-device-otp',
        data: {
          'email': email.trim(),
          'masterPasswordHash': masterPasswordHashB64,
        },
        options: Options(headers: {'Device-Identifier': deviceId}),
      );
    });
  }

  /// POST {identity}/connect/token (refresh grant), raw. Prefer
  /// [getValidAccessToken]; the interceptor refreshes automatically.
  Future<Map<String, dynamic>> refreshToken(String refreshToken) {
    final env = _requireEnv();
    return _guard(() async {
      final response = await _postRefresh(env, refreshToken);
      return asJsonMap(response.data) ?? const {};
    });
  }

  // ── Auth request endpoints ──

  /// Pending "Login with device" requests (F8, F5, A1, A2).
  ///
  /// GET {api}/auth-requests/pending, falling back once per server to the
  /// legacy GET {api}/auth-requests when the server lacks `/pending`. Items
  /// without `id`/`publicKey` are skipped; each item gets its fingerprint
  /// phrase computed here (null when its public key is malformed — never
  /// approve those) and the server clock offset. Answered requests are
  /// dropped, only the newest per `requestDeviceIdentifier` is kept, requests
  /// outside the 5-minute window are dropped unless [includeExpired], and the
  /// list is sorted newest first.
  Future<List<AuthRequest>> getPendingRequests({
    bool includeExpired = false,
  }) async {
    final env = _requireEnv();
    final Response<dynamic> response;
    if (_pendingEndpointSupported == false) {
      response = await _authGet('${env.apiUrl}/auth-requests');
    } else {
      Response<dynamic>? res;
      try {
        res = await _authGet('${env.apiUrl}/auth-requests/pending');
        _pendingEndpointSupported = true;
      } on ApiException catch (e) {
        if (_pendingEndpointSupported == true || !_isMissingEndpoint(e)) {
          rethrow;
        }
        _pendingEndpointSupported = false;
      }
      response = res ?? await _authGet('${env.apiUrl}/auth-requests');
    }
    final receivedAt = DateTime.now().toUtc();
    final offset = await _clockOffsetFrom(response, receivedAt);

    final body = response.data;
    final list = body is List ? body : (jsonGet(body, 'data') as List?) ?? [];
    final email = _session?.email;
    final parsed = <AuthRequest>[];
    for (final item in list) {
      try {
        final map = asJsonMap(item);
        if (map == null) continue;
        final request = AuthRequest.tryParse(map, serverClockOffset: offset);
        if (request == null) continue;
        final phrase = email == null
            ? null
            : _crypto.tryGenerateFingerprintPhrase(request.publicKey, email);
        parsed.add(request.copyWith(fingerprint: phrase));
      } catch (_) {
        // One malformed item must not break the whole list.
      }
    }
    return AuthRequest.selectPending(parsed, includeExpired: includeExpired);
  }

  /// PUT {api}/auth-requests/{id} → approve or deny. The body is exactly what
  /// the official clients send: `{key, masterPasswordHash: null,
  /// deviceIdentifier, requestApproved}`.
  Future<void> respondToAuthRequest({
    required String requestId,
    required bool approved,
    String? encryptedKey,
    required String deviceId,
  }) {
    final env = _requireEnv();
    return _guard(() async {
      await _dio.put<dynamic>(
        '${env.apiUrl}/auth-requests/$requestId',
        data: {
          'key': encryptedKey ?? '',
          'masterPasswordHash': null,
          'deviceIdentifier': deviceId,
          'requestApproved': approved,
        },
        options: Options(extra: {_kAuth: true}),
      );
    });
  }

  /// GET {api}/now → the server's current UTC time.
  Future<DateTime> getServerTime() {
    final env = _requireEnv();
    return _guard(() async {
      final response = await _dio.get<dynamic>('${env.apiUrl}/now');
      final t = parseServerDate(response.data);
      if (t == null) throw const FormatException('Invalid /now response');
      return t;
    });
  }

  void dispose() {
    _sessionRefreshed.close();
    _sessionEndedEvents.close();
    _dio.close(force: true);
  }

  // ── Helpers ──

  ServerEnvironment _requireEnv() {
    final env = _env ?? _session?.environment;
    if (env == null) throw StateError('Not authenticated');
    return env;
  }

  Future<Response<dynamic>> _authGet(String url) => _guard(
        () => _dio.get<dynamic>(url, options: Options(extra: {_kAuth: true})),
      );

  bool _isMissingEndpoint(ApiException e) {
    final status = e.statusCode;
    if (status == 404 || status == 405) return true;
    // Vaultwarden < 1.35 routes "/auth-requests/pending" to "/{id}".
    if (e is AuthRequestNotFoundException) return true;
    // Official self-hosted servers before 2025-06-30 (bitwarden/server
    // 20bf1455) route it to `[HttpGet("{id}")] Get(Guid id)`: "pending" fails
    // Guid binding and the model-state filter answers 400 "The model state
    // is invalid." (ErrorResponseModel(ModelState)).
    return status == 400 &&
        (e.serverMessage ?? '')
            .toLowerCase()
            .contains('model state is invalid');
  }

  Future<Duration> _clockOffsetFrom(
    Response<dynamic> response,
    DateTime receivedAt,
  ) async {
    final date = response.headers.value(HttpHeaders.dateHeader);
    if (date != null) {
      try {
        final offset = HttpDate.parse(date).difference(receivedAt);
        _clockOffset = offset;
        return offset;
      } catch (_) {
        // fall through to /now
      }
    }
    final cached = _nowOffset;
    if (cached != null) return _clockOffset = cached;
    if (!_nowOffsetAttempted) {
      _nowOffsetAttempted = true;
      try {
        final t0 = DateTime.now().toUtc();
        final server = await getServerTime();
        final t1 = DateTime.now().toUtc();
        final midpoint = t0.add(t1.difference(t0) ~/ 2);
        final offset = server.difference(midpoint);
        _nowOffset = offset;
        return _clockOffset = offset;
      } catch (_) {
        // Unknown: assume the phone clock is right.
      }
    }
    return _clockOffset ?? Duration.zero;
  }

  Future<T> _guard<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DioException catch (e) {
      throw _mapError(e);
    }
  }

  Object _mapError(DioException e) {
    final inner = e.error;
    if (inner is ApiException ||
        inner is StateError ||
        inner is ClientCertException) {
      return inner!;
    }
    final response = e.response;
    if (response != null) {
      return ApiException.fromResponse(
        response.statusCode,
        response.data,
        headers: response.headers.map,
      );
    }
    final presented = e.requestOptions.extra[_kCert] == true;
    final secure = e.requestOptions.uri.scheme == 'https';
    final cert = ClientCertificateRequiredException.classify(
          inner ?? e,
          certificatePresented: presented,
          secure: secure,
        ) ??
        (inner != null
            ? ClientCertificateRequiredException.classify(
                e,
                certificatePresented: presented,
                secure: secure,
              )
            : null);
    return cert ?? e;
  }

  Future<Response<dynamic>> _postRefresh(
    ServerEnvironment env,
    String refreshToken,
  ) =>
      _dio.post<dynamic>(
        '${env.identityUrl}/connect/token',
        data: {
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
          'client_id': 'mobile',
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );

  /// Single-flight refresh: concurrent callers share one request.
  Future<UserSession> _refreshSession() {
    final inFlight = _refreshInFlight;
    if (inFlight != null) return inFlight;
    final future = _performRefresh();
    _refreshInFlight = future;
    future.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_refreshInFlight, future)) _refreshInFlight = null;
    });
    return future;
  }

  Future<UserSession> _performRefresh() async {
    final session = _session;
    if (session == null) throw StateError('Not authenticated');
    final generation = _sessionGeneration;
    final env = _env ?? session.environment;
    final Response<dynamic> response;
    try {
      response = await _postRefresh(env, session.refreshToken);
    } on DioException catch (e) {
      if (generation != _sessionGeneration) {
        throw StateError('Session changed during refresh');
      }
      final status = e.response?.statusCode;
      if (status == 400 || status == 401) {
        final code =
            (jsonString(decodeJsonBody(e.response?.data), 'error') ?? '')
                .toLowerCase();
        if (code == 'invalid_grant') {
          throw _endSession(SessionEndReason.refreshTokenRejected);
        }
        throw const _RefreshRejected();
      }
      throw _mapError(e); // transient (network, 5xx, 429)
    }
    if (generation != _sessionGeneration) {
      throw StateError('Session changed during refresh');
    }
    final json = asJsonMap(response.data);
    if (json == null) throw const FormatException('Invalid token response');
    final token = TokenResponse.fromJson(json);
    final updated = session.copyWith(
      accessToken: token.accessToken,
      refreshToken: token.refreshToken ?? session.refreshToken,
      accessTokenExpiry: token.expiryFrom(DateTime.now()),
    );
    _session = updated;
    try {
      await _storage.saveSession(updated);
    } catch (_) {
      // Keychain unavailable (e.g. device locked); the in-memory session
      // still works and the state layer persists it from the stream.
    }
    if (generation == _sessionGeneration) _sessionRefreshed.add(updated);
    return updated;
  }

  SessionEndedException _endSession(SessionEndReason reason) {
    final existing = _sessionEnded;
    if (existing != null) return existing;
    final e = SessionEndedException(reason: reason);
    _sessionEnded = e;
    _endedRefreshToken = _session?.refreshToken;
    _sessionEndedEvents.add(e);
    return e;
  }

  /// Binds the request's origin to its client certificate / extra CA,
  /// rebuilding that origin's HTTP client when they changed.
  Future<void> _prepareTransport(RequestOptions options) async {
    final transport = _transport;
    if (transport == null) return;
    final url = options.uri.toString();
    final origin = _PerOriginAdapter.originKey(options.uri);
    SecurityContext? context;
    try {
      context = await _certs.securityContextFor(url);
      options.extra[_kCert] = await _certs.hasCertificate(url);
    } catch (_) {
      // Keychain unavailable: keep the origin's current transport rather
      // than fail every request (a missing cert then surfaces as an mTLS
      // error).
      options.extra[_kCert] = false;
      if (origin == null || transport.isBound(origin)) return;
      context = null;
    }
    if (origin != null) transport.bind(origin, context);
  }

  /// Sets the bearer token (refreshing first when it is about to expire).
  /// Returns an error to reject the request with, or null.
  Future<Object?> _authorize(RequestOptions options) async {
    final ended = _sessionEnded;
    if (ended != null) return ended;
    final session = _session;
    if (session == null) return StateError('Not authenticated');
    if (session.expiresWithin(const Duration(minutes: 1))) {
      try {
        await _refreshSession();
      } on SessionEndedException catch (e) {
        return e;
      } on _RefreshRejected {
        options.extra[_kRefreshFailed] = true;
      } catch (_) {
        // Transient: try with the current token.
      }
    }
    final current = _session;
    if (current == null) return StateError('Not authenticated');
    options.headers['Authorization'] = 'Bearer ${current.accessToken}';
    options.extra[_kToken] = current.accessToken;
    return null;
  }
}

/// Sends each request through an [IOHttpClientAdapter] bound to the TLS
/// context of *that request's* origin, so a client certificate or extra CA
/// only ever reaches the server it was imported for — also when requests to
/// two origins are in flight at once (redirects are not followed, see the
/// `BaseOptions`).
class _PerOriginAdapter implements HttpClientAdapter {
  final _routes = <String, _Route>{};
  _Route? _plain;

  /// The key [ClientCertService] stores certificates under, or null.
  static String? originKey(Uri uri) {
    try {
      return ClientCertService.originOf(uri.toString());
    } on FormatException {
      return null;
    }
  }

  bool isBound(String origin) => _routes.containsKey(origin);

  /// Uses [context] for [origin] from now on. A client built for an older
  /// context is closed once its in-flight requests are done.
  void bind(String origin, SecurityContext? context) {
    final current = _routes[origin];
    if (current != null && identical(current.context, context)) return;
    _routes[origin] = _Route(context);
    current?.adapter.close();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final key = originKey(options.uri);
    final route = (key == null ? null : _routes[key]) ??
        (_plain ??= _Route(null)); // never bound: no certificate, no CA
    return route.adapter.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {
    for (final route in _routes.values) {
      route.adapter.close(force: force);
    }
    _routes.clear();
    _plain?.adapter.close(force: force);
    _plain = null;
  }
}

class _Route {
  _Route(this.context)
      : adapter = IOHttpClientAdapter(
          createHttpClient: () => ClientCertService.httpClientFor(context),
        );

  final SecurityContext? context;
  final IOHttpClientAdapter adapter;
}

class _ApiInterceptor extends Interceptor {
  _ApiInterceptor(this.api);

  final VaultApiService api;

  DioException _wrap(RequestOptions options, Object error) => DioException(
        requestOptions: options,
        error: error,
        type: DioExceptionType.unknown,
      );

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    try {
      await api._prepareTransport(options);
    } catch (e) {
      return handler.reject(_wrap(options, e));
    }
    if (options.extra[_kAuth] != true) return handler.next(options);
    final error = await api._authorize(options);
    if (error != null) return handler.reject(_wrap(options, error));
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    if (err.response?.statusCode != 401 ||
        options.extra[_kAuth] != true ||
        options.extra[_kRetried] == true) {
      return handler.next(err);
    }
    if (options.extra[_kRefreshFailed] == true) {
      return handler.reject(_wrap(
        options,
        api._endSession(SessionEndReason.unauthorizedAfterRefreshFailure),
      ));
    }
    final session = api._session;
    if (session == null) return handler.next(err);
    final sent = options.extra[_kToken];
    // A token issued by a refresh was already refused right after that
    // refresh: another refresh (and retry) would only loop on the identity
    // server's rate limit. Pass the 401 on until the token changes (F11).
    if (sent != null && sent == api._refusedFreshToken) {
      return handler.next(err);
    }
    if (sent == session.accessToken) {
      try {
        await api._refreshSession();
      } on SessionEndedException catch (e) {
        return handler.reject(_wrap(options, e));
      } on _RefreshRejected {
        return handler.reject(_wrap(
          options,
          api._endSession(SessionEndReason.unauthorizedAfterRefreshFailure),
        ));
      } catch (_) {
        return handler.next(err); // transient refresh failure: keep the 401
      }
    }
    // Retry once with the (new) token.
    options.extra[_kRetried] = true;
    try {
      final response = await api._dio.fetch<dynamic>(options);
      handler.resolve(response);
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        final retried = e.requestOptions.extra[_kToken];
        if (retried is String) api._refusedFreshToken = retried;
      }
      handler.next(e);
    }
  }
}
