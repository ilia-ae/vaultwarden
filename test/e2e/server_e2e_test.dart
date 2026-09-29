// End-to-end tests of the app's real service layer (VaultApiService,
// CryptoService, NotificationService, ClientCertService, SecureStorageService
// over a mocked keychain, SessionNotifier) against the local Vaultwarden stack
// in tool/e2e: Vaultwarden 1.37.1 direct, the same instance behind Caddy with
// mandatory mTLS, and Vaultwarden 1.37.3. The Python harness
// (tool/e2e/requester.py) plays the new device that asks for approval.
//
// Skipped unless VA_E2E_BASE is set. To run:
//
//   tool/e2e/up.sh
//   set -a; . tool/e2e/.state/e2e.env; set +a
//   flutter test test/e2e/server_e2e_test.dart
//
// Optional: VA_E2E_PYTHON (harness python; default tool/e2e/.venv/bin/python)
// and VA_E2E_SKIP_LONG=1 (skips the 5-minute-window test, which takes ~6 min).
// Every scenario prints its observations as `[e2e] …` lines.
@Timeout(Duration(minutes: 4))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_approver/app.dart' show settingsServiceProvider;
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/models/auth_request.dart';
import 'package:vault_approver/models/cipher_string.dart';
import 'package:vault_approver/models/kdf_params.dart';
import 'package:vault_approver/models/server_environment.dart';
import 'package:vault_approver/models/token_response.dart';
import 'package:vault_approver/models/user_session.dart';
import 'package:vault_approver/providers/service_providers.dart';
import 'package:vault_approver/providers/session_provider.dart';
import 'package:vault_approver/services/client_cert_service.dart';
import 'package:vault_approver/services/crypto_service.dart';
import 'package:vault_approver/services/notification_service.dart';
import 'package:vault_approver/services/secure_storage_service.dart';
import 'package:vault_approver/services/settings_service.dart';
import 'package:vault_approver/services/vault_api.dart';
import 'package:vault_approver/utils/constants.dart';
import 'package:vault_approver/utils/error_formatter.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ─────────────────────────────────────────────────────────────── config

String? _opt(String name) {
  final v = Platform.environment[name]?.trim();
  return v == null || v.isEmpty ? null : v;
}

final String? _base = _opt('VA_E2E_BASE');
final String _mtlsBase = _opt('VA_E2E_MTLS_BASE') ?? 'https://localhost:18443';
final String? _vw137Base = _opt('VA_E2E_VW137_BASE');
final String _toolDir =
    _opt('VA_E2E_TOOL_DIR') ?? '${Directory.current.path}/tool/e2e';
final String _caPem = _opt('VA_E2E_CA_PEM') ?? '$_toolDir/.pki/ca.pem';
final String _pkiDir = File(_caPem).parent.path;
final String _p12Pass = _opt('VA_E2E_P12_PASS') ?? 'e2e-pass';
final bool _skipLong = _opt('VA_E2E_SKIP_LONG') == '1';
final String _python = _opt('VA_E2E_PYTHON') ??
    (File('$_toolDir/.venv/bin/python').existsSync()
        ? '$_toolDir/.venv/bin/python'
        : 'python3');

class _Account {
  const _Account(this.key, this.email, this.password, {this.totpSecret});

  /// Short name used by the harness (`--account`), or null for throwaway
  /// accounts (passed as `--email/--password`).
  final String? key;
  final String email;
  final String password;
  final String? totpSecret;

  List<String> get harnessArgs => key != null
      ? ['--account', key!]
      : ['--email', email, '--password', password];

  _Account withPassword(String pw) =>
      _Account(key, email, pw, totpSecret: totpSecret);
}

final _pbkdf2 = _Account(
  'pbkdf2',
  _opt('VA_E2E_PBKDF2_EMAIL') ?? 'pbkdf2@e2e.test',
  _opt('VA_E2E_PBKDF2_PASSWORD') ?? 'E2e-Pbkdf2-Passw0rd!',
);
final _argon = _Account(
  'argon',
  _opt('VA_E2E_ARGON_EMAIL') ?? 'argon@e2e.test',
  _opt('VA_E2E_ARGON_PASSWORD') ?? 'E2e-Argon2-Passw0rd!',
);
final _totpAccount = _Account(
  'totp',
  _opt('VA_E2E_TOTP_EMAIL') ?? 'totp@e2e.test',
  _opt('VA_E2E_TOTP_PASSWORD') ?? 'E2e-Totp-Passw0rd!',
  totpSecret: _opt('VA_E2E_TOTP_SECRET') ?? 'VAE2ETOTPSECRETXVAE2ETOTPSECRETX',
);

final _l10n = lookupAppLocalizations(const Locale('en'));
final _rng = Random.secure();

void _log(String message) {
  // ignore: avoid_print
  print('[e2e] $message');
}

// ─────────────────────────────────────────────────────────────── helpers

/// A device id that stays the same across runs for [salt] (so repeated runs
/// do not pile up device rows on the shared accounts).
String _stableDeviceId(String salt) {
  final h = SHA256Digest().process(Uint8List.fromList(utf8.encode(
    'va-e2e-dart|$salt',
  )));
  final hex = h.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-4${hex.substring(13, 16)}'
      '-a${hex.substring(17, 20)}-${hex.substring(20, 32)}';
}

String _randomDeviceId() => _stableDeviceId(
    '${DateTime.now().microsecondsSinceEpoch}|${_rng.nextInt(1 << 32)}');

String _runTag() =>
    '${DateTime.now().millisecondsSinceEpoch}${_rng.nextInt(1000)}';

String _randomBase32(int bytes) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  // bytes * 8 / 5 characters (20 bytes → 32 characters, no padding).
  return List.generate(bytes * 8 ~/ 5, (_) => alphabet[_rng.nextInt(32)])
      .join();
}

Uint8List _base32Decode(String input) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final clean = input.toUpperCase().replaceAll('=', '');
  final out = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final ch in clean.split('')) {
    final v = alphabet.indexOf(ch);
    if (v < 0) throw FormatException('bad base32 character $ch');
    buffer = (buffer << 5) | v;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xff);
    }
  }
  return Uint8List.fromList(out);
}

/// RFC 6238 TOTP (HMAC-SHA1, 30 s, 6 digits) for an explicit time step.
String _totp(String secretB32, int step) {
  final msg = ByteData(8)
    ..setUint32(0, step >> 32)
    ..setUint32(4, step & 0xffffffff);
  final mac = HMac(SHA1Digest(), 64)
    ..init(KeyParameter(_base32Decode(secretB32)));
  final h = mac.process(msg.buffer.asUint8List());
  final o = h[h.length - 1] & 0x0f;
  final bin =
      ((h[o] & 0x7f) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3];
  return (bin % 1000000).toString().padLeft(6, '0');
}

int _currentStep() => DateTime.now().millisecondsSinceEpoch ~/ 30000;

/// Vaultwarden accepts each TOTP time step once per user (and only a later
/// step than the last one used, ±1 step of drift). Remember the last step
/// used per database + account.
final _lastTotpStep = <String, int>{};

String _dbOf(String base) =>
    (_vw137Base != null && base == _vw137Base) ? 'vw137' : 'vw';

/// Runs [attempt] with successive TOTP codes until the server accepts one
/// (skipping steps it already consumed, waiting for the next window when no
/// usable step is left).
Future<T> _withTotp<T>(
  String base,
  _Account acc,
  Future<T> Function(String code) attempt,
) async {
  final key = '${_dbOf(base)}|${acc.email.toLowerCase()}';
  InvalidTwoFactorCodeException? last;
  for (var i = 0; i < 8; i++) {
    final now = _currentStep();
    final used = _lastTotpStep[key] ?? 0;
    var step = max(now, used + 1);
    if (step > now + 1) {
      final wait = (now + 1) * 30000 - DateTime.now().millisecondsSinceEpoch;
      _log('TOTP: step ${step - 1} already used, waiting ${wait ~/ 1000 + 1}s');
      await Future<void>.delayed(Duration(milliseconds: wait + 300));
      continue;
    }
    try {
      final result = await attempt(_totp(acc.totpSecret!, step));
      _lastTotpStep[key] = step;
      return result;
    } on InvalidTwoFactorCodeException catch (e) {
      _lastTotpStep[key] = step;
      last = e;
    }
  }
  throw last ?? StateError('TOTP login failed');
}

Future<T> _poll<T extends Object>(
  Future<T?> Function() probe, {
  Duration timeout = const Duration(seconds: 10),
  Duration interval = const Duration(milliseconds: 250),
  required String what,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final value = await probe();
    if (value != null) return value;
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after ${timeout.inSeconds}s waiting for $what');
    }
    await Future<void>.delayed(interval);
  }
}

Future<bool> _alive(String base) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final req = await client.getUrl(Uri.parse('$base/alive'));
    final res = await req.close().timeout(const Duration(seconds: 5));
    await res.drain<void>();
    return res.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// Plain authenticated JSON call with the app's access token (things the
/// app itself never does: list devices, deauthorize sessions).
Future<(int, Object?)> _rawCall(
  String method,
  String url,
  String accessToken, {
  Object? json,
}) async {
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, Uri.parse(url));
    req.headers
      ..set('Authorization', 'Bearer $accessToken')
      ..set('Accept', 'application/json');
    if (json != null) {
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(json));
    }
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    Object? body;
    try {
      body = text.isEmpty ? null : jsonDecode(text);
    } catch (_) {
      body = text;
    }
    return (res.statusCode, body);
  } finally {
    client.close(force: true);
  }
}

Future<List<Map<String, dynamic>>> _devices(String base, String token) async {
  final (status, body) = await _rawCall(
    'GET',
    '${ServerEnvironment.fromUrl(base).apiUrl}/devices',
    token,
  );
  expect(status, 200, reason: '$body');
  return ((body as Map)['data'] as List).cast<Map<String, dynamic>>();
}

/// tool/e2e/ops.py (register a throwaway account, change a password).
Future<Map<String, dynamic>> _ops(List<String> args) async {
  final r = await Process.run(
    _python,
    ['ops.py', ...args],
    workingDirectory: _toolDir,
  );
  final lines = (r.stdout as String).trim().split('\n');
  Map<String, dynamic>? json;
  try {
    json = jsonDecode(lines.last) as Map<String, dynamic>;
  } catch (_) {
    json = null;
  }
  if (r.exitCode != 0 || json == null || json['ok'] != true) {
    fail('ops.py ${args.first} failed (${r.exitCode}): ${r.stdout}\n'
        '${r.stderr}');
  }
  return json;
}

Future<_Account> _freshAccount(
  String base,
  String prefix, {
  String? totpSecret,
}) async {
  final acc = _Account(
    null,
    '$prefix-${_runTag()}@e2e.test',
    'E2e-${prefix.toUpperCase()}-${_runTag()}!',
    totpSecret: totpSecret,
  );
  await _ops([
    'register',
    '--base',
    base,
    '--email',
    acc.email,
    '--password',
    acc.password,
    '--iterations',
    '100000',
    if (totpSecret != null) ...['--totp-secret', totpSecret],
  ]);
  return acc;
}

// ─────────────────────────────────────────────────────────────── HTTP recorder

class _Exchange {
  _Exchange(this.method, this.uri, this.headers, this.body);

  final String method;
  final Uri uri;
  final Map<String, dynamic> headers;
  final Uint8List body;
  int? status;

  String get path => uri.path;
  String get bodyText => utf8.decode(body, allowMalformed: true);
  Map<String, String> get form => Uri.splitQueryString(bodyText);
  Object? get json => jsonDecode(bodyText);

  bool get isRefresh =>
      path.endsWith('/identity/connect/token') &&
      form['grant_type'] == 'refresh_token';

  bool get isPasswordGrant =>
      path.endsWith('/identity/connect/token') &&
      form['grant_type'] == 'password';

  @override
  String toString() => '$method $path${status == null ? '' : ' → $status'}';
}

/// The real dart:io adapter plus a log of every exchange (method, URL,
/// headers, exact body bytes, status). Can strip the `Date` response header
/// and add request headers (X-Real-IP for the rate-limit test).
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({this.stripDate = false, this.extraHeaders = const {}});

  final IOHttpClientAdapter _inner = IOHttpClientAdapter();
  final bool stripDate;
  final Map<String, String> extraHeaders;
  final log = <_Exchange>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    options.headers.addAll(extraHeaders);
    var body = Uint8List(0);
    if (requestStream != null) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in requestStream) {
        builder.add(chunk);
      }
      body = builder.takeBytes();
    }
    final exchange =
        _Exchange(options.method, options.uri, Map.of(options.headers), body);
    log.add(exchange);
    final response = await _inner.fetch(
      options,
      requestStream == null ? null : Stream.value(body),
      cancelFuture,
    );
    exchange.status = response.statusCode;
    if (stripDate) response.headers.remove(HttpHeaders.dateHeader);
    return response;
  }

  @override
  void close({bool force = false}) => _inner.close(force: force);

  List<_Exchange> since(int mark) => log.sublist(mark);
}

// ─────────────────────────────────────────────────────────────── app model

class _Login {
  _Login(this.session, this.token, this.userKey, this.kdf, this.keys);

  final UserSession session;
  final TokenResponse token;
  final Uint8List userKey;
  final KdfParams kdf;
  final LoginKeys keys;
}

/// Sessions of the shared accounts, reused by later tests like an app that
/// stays signed in (Vaultwarden keeps one refresh token per device).
final _sessions = <String, _Login>{};

/// Master keys per account + KDF (the KDF is the slow part).
final _keyCache = <String, LoginKeys>{};

final _liveApps = <_App>[];

/// One app install: keychain (mocked), certificate store, crypto, REST
/// client (real dart:io transport; recorded unless mTLS) and, on demand, the
/// notifications hub.
class _App {
  _App._(this.base, this.deviceId, this.storage, this.certs, this.crypto,
      this.recorder, this.api);

  final String base;
  final String deviceId;
  final SecureStorageService storage;
  final ClientCertService certs;
  final CryptoService crypto;
  final _RecordingAdapter? recorder;
  final VaultApiService api;

  NotificationService? _hub;
  final hubUris = <Uri>[];
  final hubEvents = <(DateTime, HubEvent)>[];
  _Login? current;

  String get serverUrl => ServerEnvironment.fromUrl(base).baseUrl;

  /// [record] = false uses the app's own transport (client certificates);
  /// otherwise a recording adapter replaces it (plain HTTP only).
  static Future<_App> create(
    String base, {
    required String deviceId,
    bool record = true,
    bool stripDate = false,
    Map<String, String> extraHeaders = const {},
  }) async {
    FlutterSecureStorage.setMockInitialValues(
        {SecureStorageService.keyDeviceId: deviceId});
    final storage = SecureStorageService();
    final certs = ClientCertService();
    final crypto = CryptoService();
    final recorder = record
        ? _RecordingAdapter(stripDate: stripDate, extraHeaders: extraHeaders)
        : null;
    final api = VaultApiService(
      storage,
      clientCerts: certs,
      crypto: crypto,
      httpClientAdapter: recorder,
    );
    final app = _App._(base, deviceId, storage, certs, crypto, recorder, api);
    _liveApps.add(app);
    expect(await storage.getOrCreateDeviceId(), deviceId);
    return app;
  }

  /// The hub as the app wires it (token provider = the API's valid token).
  /// [recordUris] (default: for recorded, plain-HTTP apps) swaps in a plain
  /// WebSocket factory that logs the URL; otherwise the app's default
  /// factory (client certificates) is used.
  NotificationService hub({
    HubTokenProvider? tokenProvider,
    bool? recordUris,
  }) {
    final existing = _hub;
    if (existing != null) return existing;
    final hub = NotificationService(
      tokenProvider: tokenProvider ??
          ({bool forceRefresh = false}) =>
              api.getValidAccessToken(forceRefresh: forceRefresh),
      clientCerts: certs,
      channelFactory:
          (recordUris ?? recorder != null) ? _recordingChannel : null,
      initialBackoff: const Duration(milliseconds: 300),
      maxBackoff: const Duration(seconds: 2),
    );
    hub.events.listen((e) => hubEvents.add((DateTime.now(), e)));
    return _hub = hub;
  }

  Future<WebSocketChannel> _recordingChannel(Uri uri) async {
    hubUris.add(uri);
    return IOWebSocketChannel.connect(
      uri,
      pingInterval: const Duration(seconds: 30),
      connectTimeout: const Duration(seconds: 15),
    );
  }

  Future<void> connectHub() async {
    final hub = this.hub();
    await hub.connectEnvironment(ServerEnvironment.fromUrl(base));
    await _poll(
      () async => hub.isConnected ? true : null,
      what: 'hub handshake (state ${hub.state})',
    );
  }

  Future<(DateTime, HubEvent)> waitHubEvent(
    bool Function(HubEvent e) test, {
    Duration timeout = const Duration(seconds: 5),
    required String what,
  }) =>
      _poll(
        () async {
          for (final entry in hubEvents) {
            if (test(entry.$2)) return entry;
          }
          return null;
        },
        timeout: timeout,
        interval: const Duration(milliseconds: 50),
        what: what,
      );

  Future<LoginKeys> keysFor(_Account acc, KdfParams kdf) async {
    final cacheKey = '${acc.email.toLowerCase()}|${acc.password}|'
        '${kdf.kdfType}/${kdf.iterations}/${kdf.memory}/${kdf.parallelism}';
    final cached = _keyCache[cacheKey];
    if (cached != null) return cached;
    final sw = Stopwatch()..start();
    final keys = await crypto.deriveLoginKeys(acc.email, acc.password, kdf);
    _log('KDF ${kdf.kdfType == KdfParams.typeArgon2id ? 'Argon2id' : 'PBKDF2'}'
        ' ${kdf.iterations}${kdf.memory == null ? '' : '/${kdf.memory} MiB/${kdf.parallelism}'}'
        ' for ${acc.email}: ${sw.elapsedMilliseconds} ms (isolate)');
    return _keyCache[cacheKey] = keys;
  }

  /// Password login exactly like SessionNotifier.setup (service level).
  Future<_Login> login(
    _Account acc, {
    int? twoFactorProvider,
    String? twoFactorToken,
    bool twoFactorRemember = true,
  }) async {
    final kdf = await api.prelogin(serverUrl, acc.email);
    final keys = await keysFor(acc, kdf);
    final raw = await api.login(
      serverUrl: serverUrl,
      email: acc.email,
      masterPasswordHashB64: keys.masterPasswordHashB64,
      deviceId: deviceId,
      twoFactorProvider: twoFactorProvider,
      twoFactorToken: twoFactorToken,
      twoFactorRemember: twoFactorRemember,
    );
    final token = TokenResponse.fromJson(raw);
    final userKey = crypto.decryptUserKeyWithMasterKey(
      CipherString.parse(token.requireProtectedUserKey()),
      keys.masterKey,
    );
    final session = UserSession(
      email: acc.email,
      serverUrl: serverUrl,
      accessToken: token.accessToken,
      refreshToken: token.refreshToken!,
      accessTokenExpiry: token.expiryFrom(DateTime.now()),
    );
    await storage.saveSession(session);
    api.configure(serverUrl, session);
    final remember = token.twoFactorToken;
    if (remember != null) {
      await storage.saveTwoFactorRememberToken(
        serverUrl: serverUrl,
        email: acc.email,
        token: remember,
      );
    }
    final result = _Login(session, token, userKey, kdf, keys);
    _sessions['$base|${acc.email.toLowerCase()}|$deviceId'] = result;
    return current = result;
  }

  Future<_Login> loginWithTotp(_Account acc, {bool remember = true}) =>
      _withTotp(
        base,
        acc,
        (code) => login(
          acc,
          twoFactorProvider: 0,
          twoFactorToken: code,
          twoFactorRemember: remember,
        ),
      );

  /// Reuses this device's session from an earlier test, else logs in.
  Future<_Login> signIn(_Account acc) async {
    final cached = _sessions['$base|${acc.email.toLowerCase()}|$deviceId'];
    if (cached != null) {
      await storage.saveSession(cached.session);
      api.configure(serverUrl, cached.session);
      return current = cached;
    }
    return acc.totpSecret != null ? loginWithTotp(acc) : login(acc);
  }

  Future<AuthRequest> waitPending(String id, {bool includeExpired = false}) =>
      _poll(
        () async {
          final list =
              await api.getPendingRequests(includeExpired: includeExpired);
          for (final r in list) {
            if (r.id == id) return r;
          }
          return null;
        },
        what: 'auth request $id in the pending list',
      );

  Future<void> approve(AuthRequest r) => api.respondToAuthRequest(
        requestId: r.id,
        approved: true,
        encryptedKey: crypto.encryptUserKeyForApproval(
          current!.userKey,
          r.publicKey,
        ),
        deviceId: deviceId,
      );

  Future<void> deny(AuthRequest r) => api.respondToAuthRequest(
        requestId: r.id,
        approved: false,
        deviceId: deviceId,
      );

  void dispose() {
    _hub?.dispose();
    api.dispose();
  }
}

/// The app's session layer (SessionNotifier) on top of [app]'s services.
Future<ProviderContainer> _providerApp(_App app) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(overrides: [
    settingsServiceProvider.overrideWithValue(SettingsService(prefs)),
    secureStorageProvider.overrideWithValue(app.storage),
    cryptoServiceProvider.overrideWithValue(app.crypto),
    clientCertServiceProvider.overrideWithValue(app.certs),
    apiServiceProvider.overrideWithValue(app.api),
    notificationServiceProvider.overrideWithValue(app.hub()),
  ]);
  addTearDown(container.dispose);
  await container.read(sessionProvider.future);
  return container;
}

// ─────────────────────────────────────────────────────────────── requester

final _liveRequesters = <_Requester>[];

/// tool/e2e/requester.py --json as a subprocess.
class _Requester {
  _Requester._(this.process, this.startedAt);

  final Process process;
  final DateTime startedAt;
  final events = <Map<String, dynamic>>[];
  final eventTimes = <String, DateTime>{};
  final _stderr = StringBuffer();
  final _other = StringBuffer();
  int? exitCode;

  static Future<_Requester> start(List<String> args) async {
    final process = await Process.start(
      _python,
      ['requester.py', '--json', ...args],
      workingDirectory: _toolDir,
      environment: const {'PYTHONUNBUFFERED': '1'},
    );
    final r = _Requester._(process, DateTime.now());
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(r._onLine);
    process.stderr.transform(utf8.decoder).listen(r._stderr.write);
    unawaited(process.exitCode.then((c) => r.exitCode = c));
    _liveRequesters.add(r);
    return r;
  }

  void _onLine(String line) {
    try {
      final m = jsonDecode(line);
      if (m is Map<String, dynamic>) {
        events.add(m);
        eventTimes[m['event'] as String] ??= DateTime.now();
        return;
      }
    } catch (_) {
      // not JSON
    }
    _other.writeln(line);
  }

  String get diagnostics =>
      'events: $events\nstdout: $_other\nstderr: $_stderr\nexit: $exitCode';

  Future<Map<String, dynamic>> event(
    String name, {
    Duration timeout = const Duration(seconds: 60),
  }) =>
      _poll(
        () async {
          for (final e in events) {
            if (e['event'] == name) return e;
          }
          if (exitCode != null) {
            fail('requester exited ($exitCode) without "$name"\n$diagnostics');
          }
          return null;
        },
        timeout: timeout,
        interval: const Duration(milliseconds: 100),
        what: 'requester event "$name"\n$diagnostics',
      );

  Future<int> exit({Duration timeout = const Duration(seconds: 90)}) =>
      process.exitCode.timeout(timeout, onTimeout: () {
        process.kill();
        fail('requester did not exit\n$diagnostics');
      });

  void kill() {
    if (exitCode == null) process.kill();
  }
}

// ─────────────────────────────────────────────────────────────── assertions

/// compatible_ok: PUT body = {key, masterPasswordHash: null,
/// deviceIdentifier, requestApproved}; approve key = "4." + b64(RSA-2048
/// OAEP-SHA1 ciphertext) (no MAC part); deny key = "".
Map<String, dynamic> _expectResponseBody(
  _App app,
  String id, {
  required bool approved,
  int status = 200,
}) {
  final put = app.recorder!.log.lastWhere(
    (e) => e.method == 'PUT' && e.path.endsWith('/api/auth-requests/$id'),
  );
  final body = put.json! as Map<String, dynamic>;
  expect(body.keys.toSet(),
      {'key', 'masterPasswordHash', 'deviceIdentifier', 'requestApproved'});
  expect(body.containsKey('masterPasswordHash'), isTrue);
  expect(body['masterPasswordHash'], isNull);
  expect(body['deviceIdentifier'], app.deviceId);
  expect(body['requestApproved'], approved);
  if (approved) {
    final key = body['key'] as String;
    expect(key, startsWith('4.'));
    expect(key.split('.'), hasLength(2));
    expect(key.contains('|'), isFalse);
    expect(base64Decode(key.substring(2)), hasLength(256));
  } else {
    expect(body['key'], '');
  }
  expect(put.status, status);
  return body;
}

Future<void> _approveRoundTrip(
  String label,
  String base,
  _Account acc, {
  _App? app,
  List<String> requesterArgs = const [],
}) async {
  final a = app ??
      await _App.create(base,
          deviceId: _stableDeviceId('$base|${acc.email}|approver'));
  await a.signIn(acc);
  final mark = a.recorder?.log.length ?? 0;
  final req = await _Requester.start([
    if (requesterArgs.isEmpty) ...['--base', base],
    ...requesterArgs,
    ...acc.harnessArgs,
    '--timeout',
    '90',
  ]);
  final created = await req.event('created');
  final id = created['id'] as String;
  final r = await a.waitPending(id);

  // F3: the phrase the app shows == the requester's (sdk-internal algorithm).
  expect(r.fingerprint, created['fingerprint']);
  // F5: fresh request, inside the 5-minute window (server clock).
  expect(r.isActionable, isTrue);
  expect(r.remaining(), greaterThan(const Duration(minutes: 4)));
  expect(r.remaining(), lessThanOrEqualTo(const Duration(minutes: 5)));

  // F8: the list came from GET /api/auth-requests/pending, no legacy fallback.
  final recorder = a.recorder;
  if (recorder != null) {
    final gets = recorder.since(mark).where((e) => e.method == 'GET');
    expect(gets.where((e) => e.path.endsWith('/api/auth-requests/pending')),
        isNotEmpty);
    expect(gets.where((e) => e.path.endsWith('/api/auth-requests')), isEmpty);
  }

  await a.approve(r);
  final answered = await req.event('answered');
  final verified = await req.event('verified');
  expect(await req.exit(), 0, reason: req.diagnostics);
  expect(answered['keyType'], '4');
  expect(answered['masterPasswordHash'], isNull);
  expect(verified['checks'], {
    'privateKeyDecrypts': true,
    'publicKeyMatches': true,
    'matchesMasterKeyUnwrap': true,
  });
  if (recorder != null) _expectResponseBody(a, id, approved: true);
  _log('$label approve [${acc.email}]: id $id, phrase "${r.fingerprint}" '
      '== requester, type ${r.requestDeviceType}, ip ${r.requestIpAddress}, '
      'remaining ${r.remaining().inSeconds}s, clock offset '
      '${r.serverClockOffset.inMilliseconds} ms; requester: answered '
      '${answered['keyType']}.<RSA-OAEP-SHA1>, masterPasswordHash '
      '${answered['masterPasswordHash']}, checks ${verified['checks']}, '
      'latency ${verified['latencySeconds']}s');
}

// ─────────────────────────────────────────────────────────────── suites

void _coreSuite(String label, String Function() baseOf, bool Function() up) {
  bool skipIfDown() {
    if (up()) return false;
    markTestSkipped('$label is not running');
    return true;
  }

  test(
      '[$label] PBKDF2 login: prelogin KDF, token, MAC-checked user key, '
      'F2 headers', () async {
    if (skipIfDown()) return;
    final base = baseOf();
    final app = await _App.create(base,
        deviceId: _stableDeviceId('$base|${_pbkdf2.email}|approver'));
    final login = await app.login(_pbkdf2);
    expect(login.kdf.kdfType, KdfParams.typePbkdf2Sha256);
    expect(login.kdf.iterations, 600000);
    expect(login.userKey, hasLength(64));
    expect(login.token.refreshToken, isNotNull);
    final grant = app.recorder!.log.lastWhere((e) => e.isPasswordGrant);
    expect(grant.status, 200);
    expect(grant.headers['Bitwarden-Client-Name'], kBitwardenClientName);
    expect(grant.headers['Bitwarden-Client-Version'], kBitwardenClientVersion);
    expect(grant.headers['Device-Type'], app.api.deviceType);
    expect(grant.form['client_id'], 'mobile');
    expect(grant.form['deviceType'], app.api.deviceType);
    expect(grant.form['deviceIdentifier'], app.deviceId);
    expect(grant.form['deviceName'], 'Vault Approver');
    expect(grant.form['scope'], 'api offline_access');
    final unlock = login.token.masterPasswordUnlock;
    _log('$label PBKDF2 login: kdf ${login.kdf.kdfType}/${login.kdf.iterations}'
        ', user key ${login.userKey.length} bytes, key source '
        '${unlock != null ? 'UserDecryptionOptions.MasterPasswordUnlock' : 'Key'}'
        ', expires_in ${login.token.expiresIn}s, headers '
        'Bitwarden-Client-Name=${grant.headers['Bitwarden-Client-Name']} '
        'Bitwarden-Client-Version=${grant.headers['Bitwarden-Client-Version']} '
        'Device-Type=${grant.headers['Device-Type']}');
  });

  test('[$label] F4 Argon2id login (64 MiB / 3 / 4)', () async {
    if (skipIfDown()) return;
    final base = baseOf();
    final app = await _App.create(base,
        deviceId: _stableDeviceId('$base|${_argon.email}|approver'));
    final login = await app.login(_argon);
    expect(login.kdf.kdfType, KdfParams.typeArgon2id);
    expect(login.kdf.memory, 64);
    expect(login.kdf.iterations, 3);
    expect(login.kdf.parallelism, 4);
    expect(login.userKey, hasLength(64));
    _log('$label Argon2id login OK: kdf ${login.kdf.kdfType} '
        'm=${login.kdf.memory} MiB t=${login.kdf.iterations} '
        'p=${login.kdf.parallelism}, user key decrypted (MAC verified)');
  });

  test(
      '[$label] F9 wrong password → typed InvalidCredentials with the '
      "server's text; unrecognised error → server text", () async {
    if (skipIfDown()) return;
    final base = baseOf();
    final app = await _App.create(base,
        deviceId: _stableDeviceId('$base|${_pbkdf2.email}|approver'));
    final wrong = base64Encode(List.generate(32, (_) => _rng.nextInt(256)));
    Object? error;
    try {
      await app.api.login(
        serverUrl: app.serverUrl,
        email: _pbkdf2.email,
        masterPasswordHashB64: wrong,
        deviceId: app.deviceId,
      );
    } catch (e) {
      error = e;
    }
    expect(error, isA<InvalidCredentialsException>());
    final e = error! as InvalidCredentialsException;
    expect(e.serverMessage, startsWith('Username or password is incorrect'));
    expect(formatError(e, _l10n), _l10n.errorInvalidCredentials);

    // A server error the app has no string for shows the server's own text.
    final kdf = await app.api.prelogin(app.serverUrl, _pbkdf2.email);
    final keys = await app.keysFor(_pbkdf2, kdf);
    Object? other;
    try {
      await app.api.sendEmailLoginCode(
        serverUrl: app.serverUrl,
        email: _pbkdf2.email,
        masterPasswordHashB64: keys.masterPasswordHashB64,
        deviceId: app.deviceId,
      );
    } catch (x) {
      other = x;
    }
    expect(other, isA<ServerException>());
    final shown = formatError(other!, _l10n);
    expect(shown, (other as ServerException).serverMessage);
    _log('$label F9: wrong password → ${e.runtimeType}(${e.statusCode}) '
        'server "${e.serverMessage}", UI "${formatError(e, _l10n)}"; '
        'send-email-login → ${other.runtimeType}(${other.statusCode}) '
        'UI shows server text "$shown"');
  });

  test(
      '[$label] F12 TOTP 2FA: TwoFactorRequired → wrong code typed '
      '→ TOTP logs in (remember token issued)', () async {
    if (skipIfDown()) return;
    final base = baseOf();
    final app = await _App.create(base,
        deviceId: _stableDeviceId('$base|${_totpAccount.email}|approver'));
    Object? required;
    try {
      await app.login(_totpAccount);
    } catch (e) {
      required = e;
    }
    expect(required, isA<TwoFactorRequiredException>());
    final tfr = required! as TwoFactorRequiredException;
    expect(tfr.availableProviders, contains(0));
    expect(tfr.hasTotp, isTrue);

    final right = _totp(_totpAccount.totpSecret!, _currentStep());
    final wrongCode =
        ((int.parse(right) + 500000) % 1000000).toString().padLeft(6, '0');
    Object? invalid;
    try {
      await app.login(_totpAccount,
          twoFactorProvider: 0, twoFactorToken: wrongCode);
    } catch (e) {
      invalid = e;
    }
    expect(invalid, isA<InvalidTwoFactorCodeException>());
    expect(formatError(invalid!, _l10n), _l10n.errorInvalidTwoFactorCode);

    final login = await app.loginWithTotp(_totpAccount);
    expect(login.userKey, hasLength(64));
    expect(login.token.twoFactorToken, isNotNull);
    final grant = app.recorder!.log.lastWhere((e) => e.isPasswordGrant);
    expect(grant.form['twoFactorProvider'], '0');
    expect(grant.form['twoFactorRemember'], '1');
    _log('$label TOTP: providers ${tfr.availableProviders} → wrong code '
        '${invalid.runtimeType} "${(invalid as ApiException).serverMessage}" '
        '→ TOTP login OK, remember token issued');
  });

  for (final acc in [_pbkdf2, _argon, _totpAccount]) {
    test(
        '[$label] F8 /pending + F3 phrase + approve → requester decrypts and '
        'logs in [${acc.key}]', () async {
      if (skipIfDown()) return;
      await _approveRoundTrip(label, baseOf(), acc);
    });
  }

  test(
      '[$label] deny → requester sees the denial; second approve and '
      'double approve are typed errors', () async {
    if (skipIfDown()) return;
    final base = baseOf();
    final app = await _App.create(base,
        deviceId: _stableDeviceId('$base|${_pbkdf2.email}|approver'));
    await app.signIn(_pbkdf2);

    final req = await _Requester.start([
      '--base',
      base,
      ..._pbkdf2.harnessArgs,
      '--expect',
      'deny',
      '--timeout',
      '60',
    ]);
    final id = (await req.event('created'))['id'] as String;
    final r = await app.waitPending(id);
    await app.deny(r);
    final denied = await req.event('denied');
    expect(await req.exit(), 0, reason: req.diagnostics);
    _expectResponseBody(app, id, approved: false);
    final list = await app.api.getPendingRequests(includeExpired: true);
    expect(list.map((e) => e.id), isNot(contains(id)));

    Object? second;
    try {
      await app.approve(r);
    } catch (e) {
      second = e;
    }
    expect(second, isA<AuthRequestNotFoundException>());
    expect(formatError(second!, _l10n), _l10n.errorAuthRequestNotFound);

    // Approving an already approved request (another approver was faster).
    final req2 = await _Requester.start(
        ['--base', base, ..._pbkdf2.harnessArgs, '--no-wait']);
    final id2 = (await req2.event('created'))['id'] as String;
    expect(await req2.exit(), 0, reason: req2.diagnostics);
    final r2 = await app.waitPending(id2);
    await app.approve(r2);
    Object? twice;
    try {
      await app.approve(r2);
    } catch (e) {
      twice = e;
    }
    expect(twice, isA<AuthRequestAlreadyAnsweredException>());
    _log('$label deny: requester "${denied['message']}"; PUT body '
        'requestApproved=false key="" same deviceIdentifier; second approve → '
        '${second.runtimeType} "${(second as ApiException).serverMessage}"; '
        'double approve → ${twice.runtimeType} '
        '"${(twice! as ApiException).serverMessage}"');
  });

  test(
      '[$label] hub: Type 15 within 5 s of a new request, Type 16 after '
      'approve (ws:// URL keeps the port)', () async {
    if (skipIfDown()) return;
    final base = baseOf();
    final app = await _App.create(base,
        deviceId: _stableDeviceId('$base|${_pbkdf2.email}|approver'));
    await app.signIn(_pbkdf2);
    await app.connectHub();
    final hubUri = app.hubUris.first;
    final baseUri = Uri.parse(base);
    expect(hubUri.scheme, baseUri.scheme == 'https' ? 'wss' : 'ws');
    expect(hubUri.port, baseUri.port);
    expect(hubUri.path, '/notifications/hub');

    final req = await _Requester.start(
        ['--base', base, ..._pbkdf2.harnessArgs, '--no-wait']);
    final created = await req.event('created');
    final id = created['id'] as String;
    final createdAt = req.eventTimes['created']!;
    final (at, event) = await app.waitHubEvent(
      (e) => e.type == kAuthRequestNotificationType && e.authRequestId == id,
      timeout: const Duration(seconds: 5),
      what: 'hub Type 15 for $id',
    );
    await req.exit();
    final sinceStart = at.difference(req.startedAt);
    final sinceCreated = at.difference(createdAt);
    expect(sinceStart, lessThan(const Duration(seconds: 5)));

    final r = await app.waitPending(id);
    await app.approve(r);
    final (_, response) = await app.waitHubEvent(
      (e) =>
          e.type == kAuthRequestResponseNotificationType &&
          e.authRequestId == id,
      what: 'hub Type 16 for $id',
    );
    _log('$label hub ${hubUri.scheme}://${hubUri.host}:${hubUri.port}'
        '${hubUri.path}: Type ${event.type} for $id '
        '${sinceStart.inMilliseconds} ms after '
        'the requester started (${(sinceCreated.inMicroseconds / 1000).toStringAsFixed(1)} ms relative to '
        'its "created" line), payload keys ${event.payload.keys.toList()}, '
        'ContextId ${event.contextId}; after approve Type ${response.type} '
        'ContextId ${response.contextId == app.deviceId ? '= this device' : response.contextId}');
  });
}

// ─────────────────────────────────────────────────────────────── main

void main() {
  final skip = _base == null
      ? 'server e2e: set VA_E2E_BASE (see tool/e2e/README.md)'
      : null;

  var vw137Up = false;

  group('server e2e', skip: skip, () {
    setUpAll(() async {
      expect(File('$_toolDir/requester.py').existsSync(), isTrue,
          reason: 'tool/e2e not found at $_toolDir');
      expect(await _alive(_base!), isTrue,
          reason: '$_base/alive — start the stack with tool/e2e/up.sh');
      vw137Up = _vw137Base != null && await _alive(_vw137Base!);
      _log('stack: 1.37.1 $_base, mTLS $_mtlsBase, 1.37.3 '
          '${vw137Up ? _vw137Base : 'not running'}; python $_python');
    });

    tearDown(() {
      for (final r in _liveRequesters) {
        r.kill();
      }
      _liveRequesters.clear();
      for (final a in _liveApps) {
        a.dispose();
      }
      _liveApps.clear();
    });

    group('Vaultwarden 1.37.1 direct', () {
      _coreSuite('1.37.1', () => _base!, () => true);
    });

    group('1.37.1 session lifecycle (D2)', () {
      test(
          'F10 hub reconnect: 401 on the upgrade → force-refreshed token '
          '→ connected; refresh then resume uses the new token', () async {
        final base = _base!;
        final app = await _App.create(base,
            deviceId: _stableDeviceId('$base|${_pbkdf2.email}|approver'));
        final login = await app.signIn(_pbkdf2);
        final calls = <bool>[];
        const bogus = 'e2e.invalid.token';
        app.hub(tokenProvider: ({bool forceRefresh = false}) async {
          calls.add(forceRefresh);
          if (calls.length == 1) return bogus;
          return app.api.getValidAccessToken(forceRefresh: forceRefresh);
        });
        final mark = app.recorder!.log.length;
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        await app.connectHub();
        expect(calls, [false, true]);
        expect(app.hubUris.first.queryParameters['access_token'], bogus);
        final refreshed = app.api.session!.accessToken;
        expect(refreshed, isNot(login.session.accessToken));
        expect(app.hubUris.last.queryParameters['access_token'], refreshed);
        expect(
            app.recorder!.since(mark).where((e) => e.isRefresh), hasLength(1));

        // A push arrives on the socket opened with the refreshed token.
        final req = await _Requester.start(
            ['--base', base, ..._pbkdf2.harnessArgs, '--no-wait']);
        final id = (await req.event('created'))['id'] as String;
        await app.waitHubEvent(
          (e) => e.isAuthRequest && e.authRequestId == id,
          what: 'Type 15 after the 401 reconnect',
        );

        // Refresh (as on a token expiry), then pause/resume: the new socket
        // uses the newest token.
        await Future<void>.delayed(const Duration(milliseconds: 1100));
        final newer = await app.api.getValidAccessToken(forceRefresh: true);
        expect(newer, isNot(refreshed));
        final hub = app.hub()
          ..pause()
          ..resume();
        await _poll(() async => hub.isConnected ? true : null,
            what: 'hub reconnect after resume');
        expect(app.hubUris.last.queryParameters['access_token'], newer);
        _log('F10 hub: provider calls (forceRefresh) $calls; upgrade with a '
            'bad token → 401 → refresh → connected (${app.hubUris.length} '
            'upgrades); Type 15 received on the new socket; after '
            'refresh + pause/resume the socket uses the newest token');
      });

      test('A2 GET /api/now fallback when the Date header is stripped',
          () async {
        final base = _base!;
        final app = await _App.create(base,
            deviceId: _stableDeviceId('$base|${_pbkdf2.email}|approver'),
            stripDate: true);
        await app.signIn(_pbkdf2);
        final req = await _Requester.start(
            ['--base', base, ..._pbkdf2.harnessArgs, '--no-wait']);
        final id = (await req.event('created'))['id'] as String;
        final r = await app.waitPending(id);
        await app.api.getPendingRequests();
        final nowCalls =
            app.recorder!.log.where((e) => e.path.endsWith('/api/now'));
        expect(nowCalls, hasLength(1));
        expect(nowCalls.single.status, 200);
        final offset = app.api.serverClockOffset;
        expect(offset.abs(), lessThan(const Duration(seconds: 5)));
        expect(r.serverClockOffset, offset);
        expect(r.isActionable, isTrue);
        await app.deny(r);
        _log('A2 /api/now: Date header stripped → GET /api/now called once '
            '(cached for later lists), offset ${offset.inMicroseconds} µs, '
            'request actionable with ${r.remaining().inSeconds}s left');
      });

      test(
          'F11 dead refresh token: password change → SessionEnded after '
          'exactly one refresh; A9 hub LogOut as Vaultwarden sends it',
          () async {
        final base = _base!;
        final acc = await _freshAccount(base, 'dead');
        final deviceId = _randomDeviceId();
        final app = await _App.create(base, deviceId: deviceId);
        await app.login(acc);
        await app.connectHub();
        final ended = <SessionEndedException>[];
        app.api.onSessionEnded.listen(ended.add);

        final newPassword = '${acc.password}-2';
        final changeStarted = DateTime.now();
        final changed = await _ops([
          'change-password',
          '--base',
          base,
          '--email',
          acc.email,
          '--password',
          acc.password,
          '--new-password',
          newPassword,
        ]);
        final (logOutAt, logOut) = await app.waitHubEvent(
          (e) => e.isLogOut,
          what: 'hub LogOut after the password change',
        );
        expect(logOut.contextId, changed['harnessDeviceId']);
        expect(logOut.userId, isNotEmpty);
        expect(logOut.date, isNotNull);

        final mark = app.recorder!.log.length;
        Object? error;
        try {
          await app.api.getPendingRequests();
        } catch (e) {
          error = e;
        }
        expect(error, isA<SessionEndedException>());
        expect((error! as SessionEndedException).reason,
            SessionEndReason.refreshTokenRejected);
        final traffic = app.recorder!.since(mark);
        expect(traffic.where((e) => e.isRefresh), hasLength(1));
        expect(traffic, hasLength(2));
        expect(traffic.first.status, 401);
        expect(traffic.last.status, 400);
        expect(ended, hasLength(1));

        // Dead for good: no further network traffic.
        final mark2 = app.recorder!.log.length;
        await expectLater(app.api.getPendingRequests(),
            throwsA(isA<SessionEndedException>()));
        await expectLater(app.api.getValidAccessToken(),
            throwsA(isA<SessionEndedException>()));
        expect(app.recorder!.log.length, mark2);
        expect(ended, hasLength(1));
        expect(formatError(error, _l10n), _l10n.sessionEndedOnServer);
        _log('F11: after the password change: $traffic → '
            'SessionEndedException(${(error as SessionEndedException).reason.name}), '
            'onSessionEnded emitted ${ended.length}x, later calls fail fast '
            'without traffic. A9: Vaultwarden sent LogOut Type ${logOut.type} '
            '${logOutAt.difference(changeStarted).inMilliseconds} ms after the '
            'harness started the change, ContextId = the harness device '
            '(${logOut.contextId == changed['harnessDeviceId']}), payload '
            '${logOut.payload.map((k, v) => MapEntry(k, v is DateTime ? 'DateTime(${v.toIso8601String()})' : v))}'
            ', Reason ${logOut.logOutReason}');

        // SessionNotifier on the same phone (device id kept): a hub LogOut
        // signs it out, re-login + logout + re-login keep ONE device row,
        // and a REST SessionEnded ends the session too.
        final app2 = await _App.create(base, deviceId: deviceId);
        final c = await _providerApp(app2);
        final n = c.read(sessionProvider.notifier);
        final acc2 = acc.withPassword(newPassword);
        await n.setup(
          serverUrl: base,
          email: acc2.email,
          masterPassword: acc2.password,
          onProgress: (_) {},
        );
        expect(c.read(sessionProvider).valueOrNull, isNotNull);
        await app2.hub().connectEnvironment(ServerEnvironment.fromUrl(base));
        await _poll(() async => app2.hub().isConnected ? true : null,
            what: 'provider hub connected');

        final pw3 = '${acc.password}-3';
        await _ops([
          'change-password',
          '--base',
          base,
          '--email',
          acc.email,
          '--password',
          acc2.password,
          '--new-password',
          pw3,
        ]);
        await _poll(
          () async => c.read(sessionProvider).valueOrNull == null &&
                  c.read(sessionEndNoticeProvider) ==
                      SessionEndNotice.signedOutByServer
              ? true
              : null,
          what: 'SessionNotifier.endSession(signedOutByServer) after LogOut',
        );
        expect(await app2.storage.loadSession(), isNull);
        expect(await app2.storage.getOrCreateDeviceId(), deviceId);

        final acc3 = acc.withPassword(pw3);
        Future<void> setup() => n.setup(
              serverUrl: base,
              email: acc3.email,
              masterPassword: acc3.password,
              onProgress: (_) {},
            );
        await setup();
        await n.logout();
        expect(await app2.storage.getOrCreateDeviceId(), deviceId);
        await setup();
        final rows = (await _devices(base, app2.api.session!.accessToken))
            .where((d) => d['name'] == 'Vault Approver')
            .toList();
        expect(rows, hasLength(1));
        expect(rows.single['identifier'], deviceId);

        // REST path: the hub is down (reset by logout), password changes,
        // the next call ends the session through onSessionEnded.
        final mark3 = app2.recorder!.log.length;
        await _ops([
          'change-password',
          '--base',
          base,
          '--email',
          acc.email,
          '--password',
          acc3.password,
          '--new-password',
          '${acc.password}-4',
        ]);
        await expectLater(c.read(apiServiceProvider).getPendingRequests(),
            throwsA(isA<SessionEndedException>()));
        await _poll(
          () async => c.read(sessionProvider).valueOrNull == null &&
                  c.read(sessionEndNoticeProvider) ==
                      SessionEndNotice.sessionEnded
              ? true
              : null,
          what: 'SessionNotifier.endSession(sessionEnded)',
        );
        expect(app2.recorder!.since(mark3).where((e) => e.isRefresh),
            hasLength(1));
        expect(await app2.storage.getOrCreateDeviceId(), deviceId);
        final allRows = await _deviceRowCount(base, acc, deviceId);
        _log('D2 SessionNotifier: hub LogOut → endSession(signedOutByServer), '
            'keychain session cleared, device_id kept; setup → logout → setup '
            'leaves ${rows.length} "Vault Approver" row (identifier = the '
            'kept device_id) of $allRows device rows in total; REST '
            'SessionEnded (1 refresh) → endSession(sessionEnded)');
      });

      test(
          'A6 2FA remember: provider 5 after a forced logout, user logout '
          'deletes it, a revoked token falls back to TOTP; wrong TOTP typed',
          () async {
        final base = _base!;
        final secret = _randomBase32(20);
        final acc = await _freshAccount(base, 'remember', totpSecret: secret);
        final app = await _App.create(base, deviceId: _randomDeviceId());
        final c = await _providerApp(app);
        final n = c.read(sessionProvider.notifier);
        final rec = app.recorder!;
        Future<Uint8List> setup({String? code, bool remember = true}) =>
            n.setup(
              serverUrl: base,
              email: acc.email,
              masterPassword: acc.password,
              onProgress: (_) {},
              twoFactorToken: code,
              twoFactorProvider: code == null ? null : 0,
              rememberTwoFactor: remember,
            );
        Future<String?> stored() => app.storage
            .loadTwoFactorRememberToken(serverUrl: base, email: acc.email);

        await expectLater(
            setup(),
            throwsA(isA<TwoFactorRequiredException>().having(
                (e) => e.availableProviders, 'providers', contains(0))));
        final right = _totp(secret, _currentStep());
        await expectLater(
            setup(
                code: ((int.parse(right) + 500000) % 1000000)
                    .toString()
                    .padLeft(6, '0')),
            throwsA(isA<InvalidTwoFactorCodeException>()));

        await _withTotp(base, acc, (code) => setup(code: code));
        final token1 = await stored();
        expect(token1, isNotNull);
        expect(rec.log.lastWhere((e) => e.isPasswordGrant).form,
            containsPair('twoFactorRemember', '1'));

        // Forced logout (session ended by the server) keeps the token.
        await n.endSession(SessionEndNotice.sessionEnded);
        expect(c.read(sessionProvider).valueOrNull, isNull);
        expect(await stored(), token1);
        var mark = rec.log.length;
        await setup();
        final grants = rec.since(mark).where((e) => e.isPasswordGrant).toList();
        expect(grants, hasLength(1));
        expect(grants.single.form['twoFactorProvider'], '5');
        expect(grants.single.form['twoFactorToken'], token1);
        expect(grants.single.status, 200);
        expect(c.read(sessionProvider).valueOrNull, isNotNull);

        // User logout deletes it (A13).
        await n.logout();
        expect(await stored(), isNull);
        expect(await app.storage.getOrCreateDeviceId(), app.deviceId);

        // Remember again, then the server revokes it ("Deauthorize
        // sessions" deletes every device of the account).
        await _withTotp(base, acc, (code) => setup(code: code));
        final token2 = await stored();
        expect(token2, isNotNull);
        final keys =
            await app.keysFor(acc, await app.api.prelogin(base, acc.email));
        // A separate listener (not wired to SessionNotifier) records what
        // Vaultwarden pushes for "Deauthorize sessions".
        final spyToken = app.api.session!.accessToken;
        final spyEvents = <HubEvent>[];
        final spy = NotificationService(
          tokenProvider: ({bool forceRefresh = false}) async => spyToken,
          clientCerts: app.certs,
          channelFactory: (uri) async => IOWebSocketChannel.connect(uri),
        );
        addTearDown(spy.dispose);
        spy.events.listen(spyEvents.add);
        await spy.connectEnvironment(ServerEnvironment.fromUrl(base));
        await _poll(() async => spy.isConnected ? true : null,
            what: 'spy hub connected');
        final (status, body) = await _rawCall(
          'POST',
          '${ServerEnvironment.fromUrl(base).apiUrl}/accounts/security-stamp',
          app.api.session!.accessToken,
          json: {'masterPasswordHash': keys.masterPasswordHashB64},
        );
        expect(status, 200, reason: '$body');
        final stampLogOut = await _poll(
          () async => spyEvents.where((e) => e.isLogOut).firstOrNull,
          timeout: const Duration(seconds: 5),
          what: 'LogOut after the security-stamp reset',
        );
        await expectLater(c.read(apiServiceProvider).getPendingRequests(),
            throwsA(isA<SessionEndedException>()));
        await _poll(
          () async => c.read(sessionProvider).valueOrNull == null ? true : null,
          what: 'session ended after deauthorize',
        );
        expect(c.read(sessionEndNoticeProvider), SessionEndNotice.sessionEnded);
        expect(await stored(), token2, reason: 'endSession keeps the token');

        mark = rec.log.length;
        Object? revoked;
        try {
          await setup();
        } catch (e) {
          revoked = e;
        }
        expect(revoked, isA<TwoFactorRequiredException>());
        final tries = rec.since(mark).where((e) => e.isPasswordGrant).toList();
        expect(tries, hasLength(1), reason: 'no retry loop');
        expect(tries.single.form['twoFactorProvider'], '5');
        expect(await stored(), isNull);

        await _withTotp(
            base, acc, (code) => setup(code: code, remember: false));
        expect(c.read(sessionProvider).valueOrNull, isNotNull);
        expect(await stored(), isNull);
        _log(
            'A6: providers ${(revoked! as TwoFactorRequiredException).availableProviders}; '
            'wrong TOTP → InvalidTwoFactorCodeException; TOTP+remember → token '
            'stored; endSession keeps it → setup() logs in with provider 5 '
            '(one grant, no code); logout() deletes it; after "Deauthorize '
            'sessions" (POST /api/accounts/security-stamp → $status; hub '
            'LogOut Type ${stampLogOut.type}, ContextId '
            '${stampLogOut.contextId}, payload keys '
            '${stampLogOut.payload.keys.toList()}) the next '
            'call → SessionEnded → endSession(sessionEnded) kept the token; '
            'setup() → one provider-5 grant → TwoFactorRequired, token '
            'deleted → TOTP login OK');
      });
    });

    group('mTLS front $_mtlsBase (Caddy, mandatory client certificate)', () {
      Future<_App> mtlsApp({String? p12, String? password}) async {
        final app = await _App.create(_mtlsBase,
            deviceId: _stableDeviceId('$_mtlsBase|${_pbkdf2.email}|approver'),
            record: false);
        await app.certs
            .setTrustedCaPem(_mtlsBase, File(_caPem).readAsStringSync());
        if (p12 != null) {
          await app.certs.importCertificate(
            serverUrl: _mtlsBase,
            pkcs12: File('$_pkiDir/$p12').readAsBytesSync(),
            password: password ?? _p12Pass,
          );
        }
        return app;
      }

      test(
          'F1 no client certificate → typed ClientCertificateRequired; an '
          'untrusted server certificate is not blamed on the client cert',
          () async {
        final app = await mtlsApp();
        Object? error;
        try {
          await app.api.prelogin(_mtlsBase, _pbkdf2.email);
        } catch (e) {
          error = e;
        }
        expect(error, isA<ClientCertificateRequiredException>());
        final e = error! as ClientCertificateRequiredException;
        expect(e.certificatePresented, isFalse);
        expect(isClientCertificateError(e), isTrue);

        // The hub (app's default factory) with a token but no certificate:
        // the TLS alert only backs off, it never reaches "connected".
        final hub = app.hub(
          recordUris: false,
          tokenProvider: ({bool forceRefresh = false}) async => 'any-token',
        );
        final states = <HubConnectionState>[];
        hub.states.listen(states.add);
        await hub.connectEnvironment(ServerEnvironment.fromUrl(_mtlsBase));
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(hub.isConnected, isFalse);
        expect(states, contains(HubConnectionState.backingOff));
        expect(states, isNot(contains(HubConnectionState.connected)));

        // What dart:io itself reports for Caddy's rejection (TLS 1.3).
        final probe = HttpClient(
            context: SecurityContext(withTrustedRoots: true)
              ..setTrustedCertificatesBytes(File(_caPem).readAsBytesSync()));
        Object? raw;
        try {
          final rq = await probe.getUrl(Uri.parse('$_mtlsBase/alive'));
          await (await rq.close()).drain<void>();
        } catch (x) {
          raw = x;
        } finally {
          probe.close(force: true);
        }
        expect(raw, isNotNull);

        // Without the private CA the *server* certificate fails: that must
        // not read as a client-certificate problem.
        final untrusted = await _App.create(_mtlsBase,
            deviceId: _randomDeviceId(), record: false);
        Object? tls;
        try {
          await untrusted.api.prelogin(_mtlsBase, _pbkdf2.email);
        } catch (x) {
          tls = x;
        }
        expect(tls, isNotNull);
        expect(tls, isNot(isA<ClientCertificateRequiredException>()));
        expect(isClientCertificateError(tls!), isFalse);
        _log('F1 no cert: dart:io raw ${raw.runtimeType}: "$raw" → '
            'app: $e, UI "${formatError(e, _l10n)}"; hub states '
            '${states.map((s) => s.name).toSet()}; untrusted '
            'server cert → ${tls.runtimeType} (not a client-cert error), UI '
            '"${formatError(tls, _l10n)}"');
      });

      test(
          'F1 wrong .p12 password → ClientCertBadPasswordException, nothing '
          'stored', () async {
        final app = await mtlsApp();
        await expectLater(
          app.certs.importCertificate(
            serverUrl: _mtlsBase,
            pkcs12: File('$_pkiDir/client-compat2022.p12').readAsBytesSync(),
            password: 'wrong-pass',
          ),
          throwsA(isA<ClientCertBadPasswordException>()),
        );
        expect(await app.certs.hasCertificate(_mtlsBase), isFalse);
        _log('F1 wrong .p12 password → ClientCertBadPasswordException, UI '
            '"${formatError(const ClientCertBadPasswordException(), _l10n)}"');
      });

      for (final variant in [
        'client-compat2022.p12',
        'client-openssl3.p12',
        'client-legacy.p12',
        'client-soon.p12',
      ]) {
        test('F1 $variant → login + /pending + wss hub', () async {
          final app = await mtlsApp(p12: variant);
          final info = (await app.certs.info(_mtlsBase))!;
          expect(info.isExpired(), isFalse);
          expect(info.isExpiringSoon(), variant == 'client-soon.p12');
          await app.login(_pbkdf2);
          final list = await app.api.getPendingRequests();
          await app.connectHub();
          _log('F1 $variant: CN ${info.commonName}, notAfter '
              '${info.notAfter?.toIso8601String()} (expiring soon '
              '${info.isExpiringSoon()}), login OK, /pending → '
              '${list.length} actionable, hub ${app.hub().state}');
        });
      }

      test('F1 approve round trip + Type 15 over wss through Caddy', () async {
        final app = await mtlsApp(p12: 'client-compat2022.p12');
        await app.signIn(_pbkdf2);
        final env = ServerEnvironment.fromUrl(_mtlsBase);
        final hubUri = env.hubUri(accessToken: 'x');
        expect(hubUri.scheme, 'wss');
        expect(hubUri.port, Uri.parse(_mtlsBase).port);
        expect(hubUri.path, '/notifications/hub');
        await app.connectHub();
        final started = DateTime.now();
        final req = await _Requester.start(
            ['--mtls', ..._pbkdf2.harnessArgs, '--no-wait']);
        final id = (await req.event('created'))['id'] as String;
        final (at, _) = await app.waitHubEvent(
          (e) => e.isAuthRequest && e.authRequestId == id,
          what: 'Type 15 over wss',
        );
        await req.exit();
        await app.deny(await app.waitPending(id));
        await _approveRoundTrip('mTLS', _mtlsBase, _pbkdf2,
            app: app, requesterArgs: const ['--mtls']);
        _log('F1 mTLS: hub $hubUri (port kept) got Type 15 '
            '${at.difference(started).inMilliseconds} ms after the requester '
            'started');
      });

      for (final (file, what) in [
        ('client-expired.p12', 'expired'),
        ('client-foreign.p12', 'foreign CA'),
      ]) {
        test('F1 $what certificate → ClientCertificateRequired(presented)',
            () async {
          final app = await mtlsApp(p12: file);
          Object? error;
          try {
            await app.api.prelogin(_mtlsBase, _pbkdf2.email);
          } catch (e) {
            error = e;
          }
          expect(error, isA<ClientCertificateRequiredException>());
          final e = error! as ClientCertificateRequiredException;
          expect(e.certificatePresented, isTrue);
          final info = (await app.certs.info(_mtlsBase))!;
          _log('F1 $what ($file, expired ${info.isExpired()}): $e, UI '
              '"${formatError(e, _l10n)}"');
        });
      }
    });

    group('Vaultwarden 1.37.3 direct', () {
      _coreSuite('1.37.3', () => _vw137Base!, () => vw137Up);

      test(
          '[1.37.3] 429 after exhausting the prelogin bucket → typed '
          'RateLimited', () async {
        if (!vw137Up) {
          markTestSkipped('1.37.3 is not running');
          return;
        }
        final base = _vw137Base!;
        // A private bucket: Vaultwarden keys the limit by X-Real-IP here.
        final ip = '198.51.100.${10 + _rng.nextInt(240)}';
        final app = await _App.create(base,
            deviceId: _randomDeviceId(), extraHeaders: {'X-Real-IP': ip});
        RateLimitedException? hit;
        var sent = 0;
        final sw = Stopwatch()..start();
        while (hit == null && sent < 4000) {
          final results = await Future.wait(List.generate(
            100,
            (_) => app.api
                .prelogin(base, _pbkdf2.email)
                .then<Object?>((_) => null, onError: (Object e) => e),
          ));
          sent += 100;
          for (final r in results) {
            if (r == null) continue;
            if (r is RateLimitedException) {
              hit ??= r;
            } else {
              fail('unexpected prelogin error: $r');
            }
          }
        }
        expect(hit, isNotNull, reason: 'no 429 after $sent prelogins');
        final e = hit!;
        expect(e.statusCode, 429);
        final okCount = app.recorder!.log.where((x) => x.status == 200).length;
        // Other clients keep their own bucket.
        final other = await _App.create(base, deviceId: _randomDeviceId());
        await other.api.prelogin(base, _pbkdf2.email);
        _log('1.37.3 429: $okCount prelogins OK, then '
            '${e.runtimeType}(${e.statusCode}) "${e.serverMessage}" '
            'retryAfter ${e.retryAfter} after $sent requests in '
            '${sw.elapsedMilliseconds} ms (X-Real-IP $ip); UI '
            '"${formatError(e, _l10n)}"; another IP is not limited');
      });
    });

    group('F5 5-minute window (long, last)', () {
      test(
          '[1.37.1] expired request: hidden, not actionable; Vaultwarden '
          'refuses the auth-request login after the window', () async {
        if (_skipLong) {
          markTestSkipped('VA_E2E_SKIP_LONG=1');
          return;
        }
        final base = _base!;
        final app = await _App.create(base,
            deviceId: _stableDeviceId('$base|${_pbkdf2.email}|approver'));
        await app.signIn(_pbkdf2);
        final req = await _Requester.start([
          '--base',
          base,
          ..._pbkdf2.harnessArgs,
          '--timeout',
          '600',
          '--poll',
          '2',
        ]);
        final id = (await req.event('created'))['id'] as String;
        final r = await app.waitPending(id);
        expect(r.isActionable, isTrue);
        final wait = r.expiresAt
            .add(const Duration(seconds: 10))
            .difference(r.serverNow());
        _log('F5: request $id created ${r.creationDate.toIso8601String()} '
            '(server), waiting ${wait.inSeconds}s until 5 min 10 s');
        await Future<void>.delayed(wait);

        final pending = await app.api.getPendingRequests();
        expect(pending.map((e) => e.id), isNot(contains(id)));
        final all = await app.api.getPendingRequests(includeExpired: true);
        final expired = all.firstWhere((e) => e.id == id);
        expect(expired.isActionable, isFalse);
        expect(expired.isExpired, isTrue);
        expect(expired.remaining(), Duration.zero);

        // The provider refuses this (unit-tested); the raw PUT shows why.
        await app.approve(expired);
        expect(await req.exit(timeout: const Duration(seconds: 60)), 5,
            reason: req.diagnostics);
        final error = req.events.lastWhere((e) => e['event'] == 'error');
        expect(error['stage'], 'login');
        expect(
            error['message'], contains('Username or access code is incorrect'));
        _log('F5: at ${expired.age().inSeconds}s the app hides it '
            '(isActionable false, remaining 0); Vaultwarden still accepted '
            'the PUT (HTTP 200) but the requester\'s auth-request login was '
            'refused: "${error['message']}" (exit 5)');
      }, timeout: const Timeout(Duration(minutes: 9)));
    });
  });
}

/// Total device rows of the account after one more login as the same
/// phone (the previous session is dead); still one "Vault Approver" row.
Future<int> _deviceRowCount(
  String base,
  _Account acc,
  String deviceId,
) async {
  final app = await _App.create(base, deviceId: deviceId);
  await app.login(acc.withPassword('${acc.password}-4'));
  final rows = await _devices(base, app.api.session!.accessToken);
  expect(rows.where((d) => d['name'] == 'Vault Approver'), hasLength(1));
  return rows.length;
}
