// LIVE smoke test of the app's real network code against real servers,
// without any credentials: the main Vaultwarden server behind Cloudflare and
// the Bitwarden US / EU clouds.
//
// Skipped unless VA_LIVE=1, so a plain `flutter test` never touches the
// network. To run (see test/live/README.md):
//
//   VA_LIVE=1 flutter test test/live/live_smoke_test.dart
//
// Optional: VA_LIVE_TARGETS=ddns,us,eu (subset), VA_LIVE_MAIN_URL (main
// server, default https://ddns.ilia.ae:2053), VA_LIVE_OUT=<dir> (also write
// the results as Markdown + JSON there).
//
// Request budget per target — ONE pass, no loops, no retries. A guard in the
// HTTP adapter and in the hub channel factory refuses (locally, before any
// network I/O) every request that is not on this list or is repeated:
//   1. GET  {api}/config
//   2. POST {identity}/accounts/prelogin      (fake e-mail)
//   3. POST {identity}/connect/token          (password grant, fake e-mail,
//                                              random password, fresh device id)
//   4. —    server clock offset from the HTTP `Date` header (no request)
//   5. WSS  {notifications}/hub?access_token=<obviously invalid>  (one upgrade)
//   6. GET  {api}/auth-requests/pending       (no Authorization header)
// Nothing else: no real credentials, no keychain (mocked secure storage), no
// auth requests created, no accounts registered.
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/models/json_util.dart';
import 'package:vault_approver/models/kdf_params.dart';
import 'package:vault_approver/models/server_environment.dart';
import 'package:vault_approver/services/client_cert_service.dart';
import 'package:vault_approver/services/crypto_service.dart';
import 'package:vault_approver/services/notification_service.dart';
import 'package:vault_approver/services/secure_storage_service.dart';
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

final bool _live = _opt('VA_LIVE') == '1';
final String? _outDir = _opt('VA_LIVE_OUT');

/// Reserved `.invalid` TLD (RFC 2606): can never be a real account.
const _email = 'vaultapprover-live-smoke@example.invalid';

/// Obviously invalid hub token (not a JWT).
const _invalidHubToken = 'vaultapprover-live-smoke-invalid-token';

/// The shipping iOS app's Bitwarden DeviceType (header + token form).
const _deviceType = '1';

/// Max |server − local| clock difference accepted for F5.
const _maxClockOffset = Duration(minutes: 2);

final _rng = Random.secure();

class _Target {
  const _Target({
    required this.key,
    required this.name,
    required this.serverUrl,
    required this.expectApi,
    required this.expectIdentity,
    required this.expectHub,
  });

  final String key;
  final String name;
  final String serverUrl;

  /// Expected URLs, written out independently of [ServerEnvironment] (F16).
  final String expectApi;
  final String expectIdentity;
  final String expectHub;

  ServerEnvironment get env => ServerEnvironment.fromUrl(serverUrl);
}

List<_Target> _targets() {
  final main = _opt('VA_LIVE_MAIN_URL') ?? 'https://ddns.ilia.ae:2053';
  final mainBase = ServerEnvironment.normalizeBaseUrl(main);
  final mainHub =
      '${mainBase.replaceFirst(RegExp('^https'), 'wss')}/notifications/hub';
  final all = [
    _Target(
      key: 'ddns',
      name: 'main server (Vaultwarden via Cloudflare)',
      serverUrl: mainBase,
      expectApi: '$mainBase/api',
      expectIdentity: '$mainBase/identity',
      expectHub: mainHub,
    ),
    _Target(
      key: 'us',
      name: 'Bitwarden cloud US (bitwarden.com)',
      serverUrl: ServerEnvironment.us.baseUrl,
      expectApi: 'https://api.bitwarden.com',
      expectIdentity: 'https://identity.bitwarden.com',
      expectHub: 'wss://notifications.bitwarden.com/hub',
    ),
    _Target(
      key: 'eu',
      name: 'Bitwarden cloud EU (bitwarden.eu)',
      serverUrl: ServerEnvironment.eu.baseUrl,
      expectApi: 'https://api.bitwarden.eu',
      expectIdentity: 'https://identity.bitwarden.eu',
      expectHub: 'wss://notifications.bitwarden.eu/hub',
    ),
  ];
  final only = _opt('VA_LIVE_TARGETS')
      ?.split(',')
      .map((s) => s.trim().toLowerCase())
      .where((s) => s.isNotEmpty)
      .toSet();
  if (only == null) return all;
  return all.where((t) => only.contains(t.key)).toList();
}

void _log(String message) {
  // ignore: avoid_print
  print('[live] $message');
}

String _uuidV4() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

String _oneLine(String s, [int max = 200]) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length <= max ? t : '${t.substring(0, max)}…';
}

String _fmtOffset(Duration d) =>
    '${d.isNegative ? '' : '+'}${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';

// ─────────────────────────────────────────────────────────────── budget guard

class _Exchange {
  _Exchange(this.method, this.uri, this.requestHeaders, this.requestBody,
      this.sentAt);

  final String method;
  final Uri uri;
  final Map<String, dynamic> requestHeaders;
  final Uint8List requestBody;
  final DateTime sentAt;

  /// Refused locally by the budget guard (never sent).
  bool blocked = false;
  int? status;
  Map<String, List<String>> responseHeaders = const {};
  String bodyText = '';
  DateTime? receivedAt;
  String? transportError;

  String get label => '$method ${uri.path}';

  /// A request header (case-insensitive).
  String? sentHeader(String name) => jsonGet(requestHeaders, name)?.toString();

  String? header(String name) {
    final v = responseHeaders[name.toLowerCase()];
    return v == null || v.isEmpty ? null : v.join(', ');
  }

  Map<String, String> get form {
    try {
      return Uri.splitQueryString(utf8.decode(requestBody));
    } catch (_) {
      return const {};
    }
  }

  bool get isHtml =>
      (header('content-type') ?? '').toLowerCase().contains('text/html') ||
      bodyText.trimLeft().startsWith('<');

  /// CDN / edge identification headers present on the response.
  String get edge {
    final parts = [
      for (final k in ['server', 'cf-ray', ..._edgeHeaders])
        if (header(k) != null) '$k: ${header(k)}',
    ];
    return parts.isEmpty ? '-' : parts.join('; ');
  }

  bool get viaCloudflare =>
      (header('server') ?? '').toLowerCase() == 'cloudflare' ||
      header('cf-ray') != null;

  /// Cloudflare challenge / block page (bot management, WAF).
  bool get cloudflareBlock {
    if (header('cf-mitigated') != null) return true;
    if (!isHtml) return false;
    final b = bodyText.toLowerCase();
    return b.contains('challenge-platform') ||
        b.contains('just a moment') ||
        b.contains('attention required') ||
        b.contains('cf-chl') ||
        b.contains('cloudflare');
  }

  /// `HttpDate(Date) − receivedAt` — the formula of
  /// `VaultApiService._clockOffsetFrom`.
  Duration? get clockOffset {
    final d = header(HttpHeaders.dateHeader);
    final at = receivedAt;
    if (d == null || at == null) return null;
    try {
      return HttpDate.parse(d).difference(at);
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> toJson() => {
        'request': label,
        'url': uri.toString(),
        'blocked': blocked,
        'status': status,
        'transportError': transportError,
        'sentHeaders': {
          for (final k in const [
            'Bitwarden-Client-Name',
            'Bitwarden-Client-Version',
            'Device-Type',
            'Authorization',
          ])
            if (sentHeader(k) != null)
              k: k == 'Authorization' ? '<set>' : sentHeader(k),
        },
        'responseHeaders': {
          for (final k in const [
            'server',
            'cf-ray',
            'cf-cache-status',
            'cf-mitigated',
            'content-type',
            'date',
            'retry-after',
            'www-authenticate',
            ..._edgeHeaders,
          ])
            if (header(k) != null) k: header(k),
        },
        'viaCloudflare': viaCloudflare,
        'cloudflareBlock': cloudflareBlock,
        'clockOffsetMs': clockOffset?.inMilliseconds,
        'body': label.endsWith('/config')
            ? '<${bodyText.length} bytes>'
            : _oneLine(bodyText, 400),
      };
}

/// Response headers that identify a CDN in front of the server.
const _edgeHeaders = ['via', 'x-served-by', 'x-cache', 'x-azure-ref'];

/// The allowed requests of one target, each usable once.
class _Budget {
  _Budget(Iterable<String> allowed) : _allowed = {...allowed};

  final Set<String> _allowed;
  final log = <_Exchange>[];

  bool take(String key) => _allowed.remove(key);
}

/// The app's transport for an origin without client certificate / extra CA
/// (`_PerOriginAdapter` → `_Route(null)` → `ClientCertService.httpClientFor
/// (null)`), plus the budget guard and a log of every exchange.
class _GuardedAdapter implements HttpClientAdapter {
  _GuardedAdapter(this.budget);

  final _Budget budget;
  final IOHttpClientAdapter _inner = IOHttpClientAdapter(
    createHttpClient: () => ClientCertService.httpClientFor(null),
  );

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var body = Uint8List(0);
    if (requestStream != null) {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in requestStream) {
        builder.add(chunk);
      }
      body = builder.takeBytes();
    }
    final ex = _Exchange(options.method, options.uri, Map.of(options.headers),
        body, DateTime.now().toUtc());
    budget.log.add(ex);
    if (!budget.take('${options.method} ${options.uri}')) {
      ex.blocked = true;
      throw StateError('live budget: refused ${ex.label} (not allowed or '
          'already used) — nothing was sent');
    }
    final ResponseBody response;
    try {
      response = await _inner.fetch(
        options,
        requestStream == null ? null : Stream.value(body),
        cancelFuture,
      );
    } catch (e) {
      ex.transportError = '${e.runtimeType}: ${_oneLine('$e', 300)}';
      rethrow;
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      bytes.add(chunk);
    }
    final data = bytes.takeBytes();
    ex
      ..receivedAt = DateTime.now().toUtc()
      ..status = response.statusCode
      ..responseHeaders = response.headers
      ..bodyText = utf8.decode(data, allowMalformed: true);
    return ResponseBody.fromBytes(
      data,
      response.statusCode,
      statusMessage: response.statusMessage,
      headers: response.headers,
      isRedirect: response.isRedirect,
    );
  }

  @override
  void close({bool force = false}) => _inner.close(force: force);
}

// ─────────────────────────────────────────────────────────────── results

class _Row {
  _Row(this.step, this.request);

  final String step;
  final String request;
  String status = '-';
  String result = '';
}

class _TargetResult {
  _TargetResult(this.target);

  final _Target target;
  final rows = <_Row>[];
  final failures = <String>[];
  final facts = <String, Object?>{};
  List<_Exchange> exchanges = const [];
  final hubAttempts = <String>[];

  void check(bool ok, String failure) {
    if (!ok) failures.add(failure);
  }

  String table() {
    final b = StringBuffer()
      ..writeln('### ${target.name} — ${target.serverUrl}')
      ..writeln()
      ..writeln('| # | request | HTTP | server | cf-ray | result |')
      ..writeln('|---|---|---|---|---|---|');
    for (final r in rows) {
      final ex = exchanges
          .where((e) => !e.blocked && r.request.endsWith(e.uri.path))
          .firstOrNull;
      final server = ex?.header('server') ?? '-';
      final ray = ex?.header('cf-ray') ?? '-';
      b.writeln('| ${r.step} | ${r.request} | ${r.status} | $server | $ray | '
          '${r.result.replaceAll('|', '/')} |');
    }
    b
      ..writeln()
      ..writeln('Facts: ${jsonEncode(facts)}')
      ..writeln()
      ..writeln(failures.isEmpty
          ? 'Result: PASS'
          : 'Result: FAIL\n${failures.map((f) => '- $f').join('\n')}');
    return b.toString();
  }

  Map<String, Object?> toJson() => {
        'target': target.key,
        'name': target.name,
        'serverUrl': target.serverUrl,
        'facts': facts,
        'failures': failures,
        'hubAttempts': hubAttempts,
        'exchanges': exchanges.map((e) => e.toJson()).toList(),
      };
}

// ─────────────────────────────────────────────────────────────── one target

Future<void> _runTarget(_TargetResult r) async {
  final t = r.target;
  FlutterSecureStorage.setMockInitialValues({}); // no keychain, no secrets
  final env = t.env;

  // F16: URL layout (checked before any request).
  final hubUrl = env.hubUri().toString();
  r.facts['apiUrl'] = env.apiUrl;
  r.facts['identityUrl'] = env.identityUrl;
  r.facts['hubUrl'] = hubUrl;
  r.check(env.apiUrl == t.expectApi, 'F16 apiUrl ${env.apiUrl}');
  r.check(env.identityUrl == t.expectIdentity,
      'F16 identityUrl ${env.identityUrl}');
  r.check(hubUrl == t.expectHub, 'F16 hub URL $hubUrl != ${t.expectHub}');

  final budget = _Budget([
    'GET ${env.apiUrl}/config',
    'POST ${env.identityUrl}/accounts/prelogin',
    'POST ${env.identityUrl}/connect/token',
    'GET ${env.apiUrl}/auth-requests/pending',
  ]);
  r.exchanges = budget.log; // live view: kept even if a step throws
  final storage = SecureStorageService();
  final certs = ClientCertService();
  final crypto = CryptoService();
  final api = VaultApiService(
    storage,
    clientCerts: certs,
    crypto: crypto,
    httpClientAdapter: _GuardedAdapter(budget),
    deviceType: _deviceType,
  );
  // For the two calls the app has no method for (config, unauthenticated
  // pending): the app's BaseOptions and headers, the same guarded transport.
  final raw = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    headers: VaultApiService.defaultHeaders(_deviceType),
    followRedirects: false,
  ))
    ..httpClientAdapter = _GuardedAdapter(budget);
  NotificationService? hub;

  _Exchange? exchangeFor(String method, String url) => budget.log
      .where((e) => !e.blocked && e.method == method && '${e.uri}' == url)
      .lastOrNull;

  try {
    // ── 1. GET {api}/config ──
    final configUrl = '${env.apiUrl}/config';
    final row1 = _Row('1', 'GET ${Uri.parse(configUrl).path}');
    r.rows.add(row1);
    try {
      final res = await raw.get<dynamic>(configUrl);
      row1.status = '${res.statusCode}';
      final cfg = asJsonMap(res.data);
      r.check(cfg != null, 'config: response is not a JSON object');
      final version = jsonString(cfg, 'version');
      final serverName = jsonString(jsonGet(cfg, 'server'), 'name');
      final serverVer = jsonString(jsonGet(cfg, 'server'), 'version');
      final gitHash = jsonString(cfg, 'gitHash');
      r.facts['serverVersion'] = version;
      r.facts['serverName'] = serverName;
      if (serverVer != null) r.facts['serverImplVersion'] = serverVer;
      r.facts['gitHash'] = gitHash;
      r.check(
          version != null && version.isNotEmpty, 'config: no "version" field');
      row1.result = 'JSON; version $version'
          '${serverName == null ? '' : ' ($serverName'
              '${serverVer == null ? '' : ' $serverVer'})'}'
          '${gitHash == null ? '' : ', gitHash $gitHash'}';
    } on DioException catch (e) {
      final res = e.response;
      row1.status = '${res?.statusCode ?? '-'}';
      final typed = res == null
          ? null
          : ApiException.fromResponse(res.statusCode, res.data,
              headers: res.headers.map);
      row1.result = 'FAILED: ${typed ?? '${e.type} ${e.error ?? e.message}'}';
      r.check(false, 'config: ${row1.result}');
    }

    // ── 2. prelogin (app) ──
    final row2 = _Row(
        '2',
        'POST ${Uri.parse(env.identityUrl).path}'
            '/accounts/prelogin');
    r.rows.add(row2);
    KdfParams? kdf;
    try {
      kdf = await api.prelogin(t.serverUrl, _email);
      row2.status =
          '${exchangeFor('POST', '${env.identityUrl}/accounts/prelogin')?.status}';
      r.facts['kdf'] = '$kdf';
      r.facts['kdfType'] = kdf.kdfType;
      r.facts['kdfServerSalt'] = kdf.salt != null;
      try {
        kdf.validate(); // F15 minimums / sanity maxima
        row2.result = '$kdf — F15 validate() OK'
            '${kdf.salt == null ? '' : ', server salt present'}';
      } on ApiException catch (e) {
        row2.result = '$kdf — F15 REJECTED: $e';
        r.check(false, 'prelogin: F15 validate() rejected $kdf: $e');
      }
    } catch (e) {
      row2.status =
          '${exchangeFor('POST', '${env.identityUrl}/accounts/prelogin')?.status ?? '-'}';
      row2.result = 'FAILED: ${e.runtimeType}: ${_oneLine('$e')}';
      r.check(false, 'prelogin: ${row2.result}');
    }

    // ── 3. password grant (app), fake e-mail + random password ──
    final tokenUrl = '${env.identityUrl}/connect/token';
    final row3 = _Row('3', 'POST ${Uri.parse(tokenUrl).path}');
    r.rows.add(row3);
    final deviceId = _uuidV4();
    r.facts['deviceIdentifier'] = deviceId;
    final password = base64Url
        .encode(List<int>.generate(24, (_) => _rng.nextInt(256)))
        .replaceAll('=', '');
    String hash;
    if (kdf != null) {
      final sw = Stopwatch()..start();
      try {
        hash = (await crypto
                .deriveLoginKeys(_email, password, kdf)
                .timeout(const Duration(seconds: 120)))
            .masterPasswordHashB64;
        r.facts['kdfMillis'] = sw.elapsedMilliseconds;
      } catch (e) {
        // Weak/unsupported KDF or too slow: the server sees random bytes
        // either way.
        hash = base64.encode(List<int>.generate(32, (_) => _rng.nextInt(256)));
        r.facts['kdfMillis'] = 'skipped (${e.runtimeType})';
      }
    } else {
      hash = base64.encode(List<int>.generate(32, (_) => _rng.nextInt(256)));
    }
    Object? loginError;
    try {
      await api.login(
        serverUrl: t.serverUrl,
        email: _email,
        masterPasswordHashB64: hash,
        deviceId: deviceId,
      );
    } catch (e) {
      loginError = e;
    }
    final tokenEx = exchangeFor('POST', tokenUrl);
    row3.status = '${tokenEx?.status ?? '-'}';
    r.facts['loginError'] = '$loginError';
    if (loginError == null) {
      row3.result = 'UNEXPECTED: login succeeded';
      r.check(false, 'login: succeeded with a fake account?!');
    } else {
      row3.result = '${loginError.runtimeType}'
          '${loginError is ApiException ? ' — "${loginError.serverMessage}"' : ': ${_oneLine('$loginError')}'}';
    }
    r.check(
        loginError is InvalidCredentialsException,
        'login: expected InvalidCredentialsException, got '
        '${loginError.runtimeType}: $loginError');
    r.check(loginError is! ClientVersionRejectedException,
        'F2: client version rejected: $loginError');
    if (tokenEx != null) {
      final sent = {
        for (final k in const [
          'Bitwarden-Client-Name',
          'Bitwarden-Client-Version',
          'Device-Type',
        ])
          k: tokenEx.sentHeader(k),
      };
      r.check(sent['Bitwarden-Client-Name'] == kBitwardenClientName,
          'F2: Bitwarden-Client-Name header ${sent['Bitwarden-Client-Name']}');
      r.check(
          sent['Bitwarden-Client-Version'] == kBitwardenClientVersion,
          'F2: Bitwarden-Client-Version header '
          '${sent['Bitwarden-Client-Version']}');
      r.check(sent['Device-Type'] == _deviceType,
          'F2: Device-Type header ${sent['Device-Type']}');
      final form = tokenEx.form;
      r.check(form['deviceType'] == _deviceType,
          'form deviceType ${form['deviceType']} != header');
      r.check(form['deviceIdentifier'] == deviceId,
          'form deviceIdentifier ${form['deviceIdentifier']}');
      r.check(form['grant_type'] == 'password' && form['client_id'] == 'mobile',
          'form grant_type/client_id ${form['grant_type']}/${form['client_id']}');
      r.facts['sentClientHeaders'] = '${sent['Bitwarden-Client-Name']}/'
          '${sent['Bitwarden-Client-Version']}/Device-Type ${sent['Device-Type']}';
      final lower = tokenEx.bodyText.toLowerCase();
      r.check(
          !lower.contains('version_header_missing') &&
              !lower.contains('invalid_client_version'),
          'F2: body mentions a client-version error: '
          '${_oneLine(tokenEx.bodyText)}');
      r.check(tokenEx.status != 403 && tokenEx.status != 429,
          'login: HTTP ${tokenEx.status}');
      r.check(!tokenEx.isHtml && !tokenEx.cloudflareBlock,
          'login: HTML / Cloudflare block page: ${_oneLine(tokenEx.bodyText)}');
      r.facts['loginStatus'] = tokenEx.status;
      r.facts['loginBody'] = _oneLine(tokenEx.bodyText, 400);
      if (loginError is ApiException) {
        final msg = loginError.serverMessage;
        // F9: the server's own text, verbatim.
        r.check(
            msg != null && tokenEx.bodyText.contains(msg),
            'F9: serverMessage "$msg" is not verbatim in the body '
            '${_oneLine(tokenEx.bodyText)}');
        r.check(
            (msg ?? '')
                .toLowerCase()
                .contains('username or password is incorrect'),
            'F9: unexpected message "$msg"');
      }
    } else {
      r.check(false, 'login: no token exchange recorded');
    }

    // ── 5. hub with an invalid token (app's NotificationService) ──
    final row5 = _Row('5', 'WSS ${Uri.parse(hubUrl).path}');
    Object? hubError;
    var attempts = 0;
    hub = NotificationService(
      clientCerts: certs,
      initialBackoff: const Duration(seconds: 1),
      maxBackoff: const Duration(seconds: 1),
      // Identical to NotificationService._defaultChannel, plus the budget
      // guard (one upgrade) and a record of the upgrade error.
      channelFactory: (uri) async {
        attempts++;
        // Without the query (the token).
        r.hubAttempts.add('${uri.scheme}://${uri.authority}${uri.path}');
        if (attempts > 1) {
          throw StateError('live budget: hub reconnect refused locally');
        }
        HttpClient? client;
        try {
          final https =
              uri.replace(scheme: uri.scheme == 'wss' ? 'https' : 'http');
          client = await certs.createHttpClient(https.toString());
        } catch (_) {
          client = null;
        }
        final channel = IOWebSocketChannel.connect(
          uri,
          customClient: client,
          pingInterval: const Duration(seconds: 30),
          connectTimeout: const Duration(seconds: 15),
        );
        channel.ready.then<void>(
          (_) => client?.close(),
          onError: (Object e) {
            hubError = e;
            client?.close(force: true);
          },
        );
        return channel;
      },
    );
    final states = <HubConnectionState>[];
    final outcome = Completer<HubConnectionState>();
    final stateSub = hub.states.listen((s) {
      states.add(s);
      if (s != HubConnectionState.connecting && !outcome.isCompleted) {
        outcome.complete(s);
      }
    });
    HubConnectionState? first;
    try {
      await hub.connect(t.serverUrl, _invalidHubToken);
      first = await outcome.future.timeout(const Duration(seconds: 25));
    } on TimeoutException {
      first = hub.state;
    } finally {
      hub.reset(); // stop right after the first failure (no reconnects)
    }
    // Longer than initialBackoff: a scheduled reconnect would show up here.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await stateSub.cancel();
    Object? inner = hubError;
    if (inner is WebSocketChannelException) inner = inner.inner ?? inner;
    final wsStatus = inner is WebSocketException ? inner.httpStatusCode : null;
    r.facts['hubState'] = first.name;
    r.facts['hubStates'] = states.map((s) => s.name).toList();
    r.facts['hubUpgradeStatus'] = wsStatus;
    r.facts['hubError'] =
        hubError == null ? null : _oneLine('${inner.runtimeType}: $inner', 300);
    r.facts['hubAttempts'] = attempts;
    row5
      ..status = '${wsStatus ?? '-'}'
      ..result =
          'state ${first.name}; ${hubError == null ? 'no error' : _oneLine('${inner.runtimeType}: $inner', 120)}; '
              'attempts $attempts';
    r.rows.add(row5);
    r.check(attempts == 1, 'hub: $attempts upgrade attempts (expected 1)');
    r.check(r.hubAttempts.isNotEmpty && r.hubAttempts.first == t.expectHub,
        'F16: hub dialled ${r.hubAttempts.firstOrNull} != ${t.expectHub}');
    r.check(
        first == HubConnectionState.waitingForToken,
        'F10: hub state after the first failure is ${first.name} '
        '(expected waitingForToken = typed auth failure)');
    r.check(
        wsStatus == 401,
        'F10: hub upgrade answered ${wsStatus ?? 'no HTTP status'} '
        '(expected 401): ${r.facts['hubError']}');

    // ── 6. GET {api}/auth-requests/pending without a token ──
    final pendingUrl = '${env.apiUrl}/auth-requests/pending';
    final row6 = _Row('6', 'GET ${Uri.parse(pendingUrl).path}');
    r.rows.add(row6);
    Object? pendingError;
    Response<dynamic>? pendingRes;
    DateTime? pendingReceivedAt;
    try {
      pendingRes = await raw.get<dynamic>(pendingUrl);
      pendingReceivedAt = DateTime.now().toUtc();
    } on DioException catch (e) {
      pendingReceivedAt = DateTime.now().toUtc();
      final res = e.response;
      pendingRes = res;
      // The app's mapping (VaultApiService._mapError → fromResponse).
      pendingError = res == null
          ? e
          : ApiException.fromResponse(res.statusCode, res.data,
              headers: res.headers.map);
    }
    row6
      ..status = '${pendingRes?.statusCode ?? '-'}'
      ..result = pendingError == null
          ? 'UNEXPECTED success'
          : '${pendingError.runtimeType}'
              '${pendingError is ApiException ? '(${pendingError.statusCode})'
                  '${pendingError.serverMessage == null ? '' : ' "${pendingError.serverMessage}"'}' : ': ${_oneLine('$pendingError', 120)}'}'
              '; isAuthError ${isAuthError(pendingError)}';
    r.facts['pendingError'] = '$pendingError';
    r.check(pendingError is ServerException && pendingError.statusCode == 401,
        'pending: expected typed ServerException(401), got $pendingError');
    r.check(pendingError != null && isAuthError(pendingError),
        'pending: isAuthError false for $pendingError');

    // ── 4. server clock offset from `Date` (F5) ──
    final row4 = _Row('4', 'Date header (F5, from #6)');
    r.rows.insert(3, row4);
    final date = pendingRes?.headers.value(HttpHeaders.dateHeader);
    Duration? offset;
    if (date != null) {
      try {
        // Exactly VaultApiService._clockOffsetFrom.
        offset = HttpDate.parse(date).difference(pendingReceivedAt);
      } catch (_) {
        offset = null;
      }
    }
    final perExchange = {
      for (final e in budget.log.where((e) => !e.blocked))
        e.label: e.clockOffset == null ? null : _fmtOffset(e.clockOffset!),
    };
    r.facts['date'] = date;
    r.facts['clockOffset'] = offset == null ? null : _fmtOffset(offset);
    r.facts['clockOffsetPerExchange'] = perExchange;
    row4
      ..status = '-'
      ..result = offset == null
          ? 'NO usable Date header ($date)'
          : 'Date "$date" → offset ${_fmtOffset(offset)} (all: '
              '${perExchange.values.join(', ')})';
    r.check(date != null, 'F5: no Date header on the pending response');
    r.check(offset != null && offset.abs() < _maxClockOffset,
        'F5: offset ${offset == null ? 'not computed' : _fmtOffset(offset)}');
  } finally {
    hub?.dispose();
    raw.close(force: true);
    api.dispose();
    certs.dispose();
  }

  // ── Global budget / Cloudflare checks ──
  final blocked = r.exchanges.where((e) => e.blocked).toList();
  final sent = r.exchanges.where((e) => !e.blocked).toList();
  r.check(blocked.isEmpty,
      'budget: refused ${blocked.map((e) => e.label).join(', ')}');
  r.check(
      sent.length == 4, 'budget: ${sent.length} HTTP requests (expected 4)');
  for (final e in sent) {
    r.check(e.status != 429, '${e.label}: HTTP 429');
    r.check(e.status != 403, '${e.label}: HTTP 403');
    r.check(!e.cloudflareBlock,
        '${e.label}: Cloudflare block/challenge page ${_oneLine(e.bodyText)}');
  }
  r.facts['viaCloudflare'] = {
    for (final e in sent) e.label: e.viaCloudflare,
  };
  r.facts['edge'] = {
    for (final e in sent) e.label: e.edge,
  };
  r.facts['cfMitigated'] = sent.any((e) => e.header('cf-mitigated') != null);
}

// ─────────────────────────────────────────────────────────────── main

void main() {
  final results = <_TargetResult>[];

  group('live smoke (real servers, no credentials)', () {
    tearDownAll(() {
      if (results.isEmpty) return;
      final stamp = DateTime.now()
          .toUtc()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-');
      final md = StringBuffer()
        ..writeln('# VaultApprover live smoke — $stamp')
        ..writeln()
        ..writeln('Client headers: Bitwarden-Client-Name '
            '$kBitwardenClientName, Bitwarden-Client-Version '
            '$kBitwardenClientVersion, Device-Type $_deviceType; '
            'fake e-mail $_email')
        ..writeln();
      for (final r in results) {
        md
          ..writeln(r.table())
          ..writeln();
      }
      for (final line in md.toString().split('\n')) {
        _log(line);
      }
      final dir = _outDir;
      if (dir != null) {
        Directory(dir).createSync(recursive: true);
        File('$dir/live_smoke_$stamp.md').writeAsStringSync(md.toString());
        File('$dir/live_smoke_$stamp.json').writeAsStringSync(
            const JsonEncoder.withIndent('  ')
                .convert(results.map((r) => r.toJson()).toList()));
        _log('results written to $dir/live_smoke_$stamp.{md,json}');
      }
    });

    for (final t in _targets()) {
      test('${t.key}: ${t.name}', () async {
        final r = _TargetResult(t);
        results.add(r); // reported in tearDownAll even if a step throws
        await _runTarget(r);
        expect(r.failures, isEmpty, reason: r.failures.join('\n'));
      });
    }
  },
      skip: _live
          ? false
          : 'live smoke test: set VA_LIVE=1 to run against real servers');
}
