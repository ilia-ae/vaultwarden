// LIVE end-to-end test of "Log in with device" against a REAL self-hosted
// Vaultwarden and a REAL account, driven by the app's real services
// (VaultApiService, CryptoService, NotificationService, ClientCertService,
// SecureStorageService over a mocked keychain) wired like
// test/e2e/server_e2e_test.dart. tool/e2e/requester.py plays the new device
// that asks for approval.
//
// Skipped unless VA_LIVE_BASE, VA_LIVE_EMAIL and VA_LIVE_PASSWORD are all set,
// so a plain `flutter test` never touches a server. Read test/live/README.md
// first: it lists exactly what one run changes on the account.
//
//   VA_LIVE_BASE=https://vault.example.com VA_LIVE_EMAIL=… VA_LIVE_PASSWORD=… \
//   VA_LIVE_PYTHON=tool/e2e/.venv/bin/python \
//   flutter test test/live/live_auth_test.dart
//
// Optional: VA_LIVE_TOTP_SECRET (base32; accounts with authenticator 2FA),
// VA_LIVE_PYTHON (default tool/e2e/.venv/bin/python, else python3). For a
// server behind mandatory mTLS: VA_LIVE_P12 + VA_LIVE_P12_PASS (app side),
// VA_LIVE_CLIENT_CRT + VA_LIVE_CLIENT_KEY (the same identity as PEM, for the
// requester), VA_LIVE_CA (PEM of a private CA that signed the server cert).
//
// App-side request budget. One pass, no retries. A guard in the HTTP adapter
// and in the hub channel factory refuses every other request, and every
// request over its count, locally before anything is sent:
//   GET  {api}/version                 1  server version (unauthenticated)
//   POST {identity}/accounts/prelogin  1
//   POST {identity}/connect/token      1  password grant only, no refresh
//   WSS  {base}/notifications/hub      2  one connect + at most one reconnect
//   GET  {api}/auth-requests/pending  12  ≤ 5 polls per request + 1 check
//   PUT  {api}/auth-requests/{id}      2  one approve + one deny
//   GET  {api}/devices                 1  our device row exists exactly once
//   GET  {api}/now                     1  only if a response has no `Date`
// Requester side (requester.py, not guarded): per auth request one anonymous
// POST {api}/auth-requests plus a response poll every 2 s; after the approval
// one auth-request login and one GET {api}/sync. First run only: one prelogin
// and one password login (plus a TOTP retry) to register its device.
//
// Nothing secret is printed: no password, hash, token, TOTP code or key; the
// e-mail is masked. Every line the test prints goes through `_redact`.
@Timeout(Duration(minutes: 8))
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
import 'package:pointycastle/export.dart';
import 'package:vault_approver/models/auth_request.dart';
import 'package:vault_approver/models/cipher_string.dart';
import 'package:vault_approver/models/json_util.dart';
import 'package:vault_approver/models/server_environment.dart';
import 'package:vault_approver/models/token_response.dart';
import 'package:vault_approver/models/user_session.dart';
import 'package:vault_approver/services/client_cert_service.dart';
import 'package:vault_approver/services/crypto_service.dart';
import 'package:vault_approver/services/notification_service.dart';
import 'package:vault_approver/services/secure_storage_service.dart';
import 'package:vault_approver/services/vault_api.dart';
import 'package:vault_approver/utils/constants.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

// ─────────────────────────────────────────────────────────────── config

String? _opt(String name) {
  final v = Platform.environment[name]?.trim();
  return v == null || v.isEmpty ? null : v;
}

/// Not trimmed (a master password may start or end with a space).
String? _raw(String name) {
  final v = Platform.environment[name];
  return v == null || v.isEmpty ? null : v;
}

final String? _base = _opt('VA_LIVE_BASE');
final String? _email = _opt('VA_LIVE_EMAIL');
final String? _password = _raw('VA_LIVE_PASSWORD');
final String? _totpSecret =
    _opt('VA_LIVE_TOTP_SECRET')?.replaceAll(RegExp(r'[\s=]'), '').toUpperCase();
final String? _p12 = _opt('VA_LIVE_P12');
final String? _p12Pass = _raw('VA_LIVE_P12_PASS');
final String? _caPem = _opt('VA_LIVE_CA');
final String? _clientCrt = _opt('VA_LIVE_CLIENT_CRT');
final String? _clientKey = _opt('VA_LIVE_CLIENT_KEY');

final String _repo = Directory.current.path;
final String _toolDir = '$_repo/tool/e2e';
final String _liveDir = '$_repo/test/live';

/// The app device's fixed `deviceIdentifier` (gitignored), so re-runs log in
/// as the same device instead of adding a device row each time.
final String _deviceIdFile = '$_liveDir/.device_id';

/// requester.py's state (its device id, "registered", a 2FA remember token on
/// TOTP accounts): gitignored, separate from the local e2e stack's state.
final String _requesterStateDir = '$_liveDir/.state';

final String _python = _opt('VA_LIVE_PYTHON') ??
    (File('$_toolDir/.venv/bin/python').existsSync()
        ? '$_toolDir/.venv/bin/python'
        : 'python3');

/// `deviceName` of the app's device row. The app itself sends
/// "Vault Approver"; the test transport renames it in the token form.
const _deviceName = 'VaultApprover live test';
const _requesterDeviceName = 'VaultApprover live test requester';

/// requester.py's default Bitwarden DeviceType (9 = Chrome).
const _requesterDeviceType = 9;

/// The shipping iOS app's Bitwarden DeviceType (header + token form).
const _deviceType = '1';

/// Type 15 must reach the hub within this time of the requester's
/// "created" line.
const _hubDeadline = Duration(seconds: 10);

/// Polls of GET /pending per auth request (1 s apart).
const _pendingPolls = 5;

final _rng = Random.secure();

// ─────────────────────────────────────────────────────────────── redaction

final _secrets = <String>{};

void _secret(String? value) {
  if (value != null && value.length >= 6) _secrets.add(value);
}

String _maskEmail(String email) {
  final at = email.indexOf('@');
  if (at <= 0) return '***';
  return '${email[0]}***${email.substring(at)}';
}

/// Removes every known secret, JWT-looking string and credential query
/// parameter from [text], and masks the account e-mail.
String _redact(String text) {
  var out = text;
  final byLength = _secrets.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final s in byLength) {
    out = out.replaceAll(s, '<redacted>');
  }
  final email = _email;
  if (email != null) {
    out = out.replaceAll(
        RegExp(RegExp.escape(email), caseSensitive: false), _maskEmail(email));
  }
  out = out.replaceAll(
      RegExp(r'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*'),
      '<jwt>');
  return out.replaceAllMapped(
    RegExp(r'(access_token|refresh_token|code|password|twoFactorToken)='
        r'[^&\s"]+'),
    (m) => '${m[1]}=<redacted>',
  );
}

void _log(String message) {
  for (final line in _redact(message).split('\n')) {
    // ignore: avoid_print
    print('[live-auth] $line');
  }
}

String _oneLine(String s, [int max = 400]) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length <= max ? t : '${t.substring(0, max)}…';
}

/// A readable, redacted description of any failure.
String _describe(Object e) {
  final text = switch (e) {
    TestFailure() => e.message ?? '$e',
    ApiException() => '$e',
    DioException() => 'DioException(${e.type.name}) '
        '${e.error == null ? e.message ?? '' : '${e.error.runtimeType}: ${e.error}'}',
    _ => '${e.runtimeType}: $e',
  };
  return _redact(_oneLine(text, 1200));
}

// ─────────────────────────────────────────────────────────────── helpers

String _uuidV4() {
  final b = List<int>.generate(16, (_) => _rng.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

final _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

/// The fixed device id from test/live/.device_id (created on the first run),
/// and whether it was just created.
(String, bool) _loadOrCreateDeviceId() {
  final f = File(_deviceIdFile);
  if (f.existsSync()) {
    final id = f.readAsStringSync().trim();
    if (!_uuidPattern.hasMatch(id)) {
      fail('$_deviceIdFile does not hold a UUID; delete it to start over '
          '(the next run then adds a new device row)');
    }
    return (id, false);
  }
  final id = _uuidV4();
  f.parent.createSync(recursive: true);
  f.writeAsStringSync('$id\n');
  return (id, true);
}

/// Whether requester.py already registered its device for this server and
/// account (`bwproto.state_key`: `base|email|requester-<type>`).
bool _requesterRegistered(String base, String email) {
  try {
    final state =
        jsonDecode(File('$_requesterStateDir/state.json').readAsStringSync())
            as Map;
    final key = '$base|${email.toLowerCase()}|requester-$_requesterDeviceType';
    return (state[key] as Map?)?['registered'] == true;
  } catch (_) {
    return false;
  }
}

Uint8List _base32Decode(String input) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final out = <int>[];
  var buffer = 0;
  var bits = 0;
  for (final ch in input.toUpperCase().replaceAll('=', '').split('')) {
    final v = alphabet.indexOf(ch);
    if (v < 0) {
      throw const FormatException('VA_LIVE_TOTP_SECRET is not base32');
    }
    buffer = (buffer << 5) | v;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      out.add((buffer >> bits) & 0xff);
    }
  }
  return Uint8List.fromList(out);
}

/// RFC 6238 TOTP (HMAC-SHA1, 30 s, 6 digits), as in the e2e suite.
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

Future<T> _poll<T extends Object>(
  Future<T?> Function() probe, {
  required Duration timeout,
  Duration interval = const Duration(milliseconds: 100),
  required String Function() what,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    final value = await probe();
    if (value != null) return value;
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out after ${timeout.inMilliseconds / 1000} s waiting for '
          '${what()}');
    }
    await Future<void>.delayed(interval);
  }
}

String _ms(Duration d) => '${d.inMilliseconds} ms';

/// `12.3 ms after` / `4.0 ms before` (the hub push can beat the requester's
/// own "created" line).
String _rel(Duration d) {
  final ms = (d.inMicroseconds.abs() / 1000).toStringAsFixed(1);
  return '$ms ms ${d.isNegative ? 'before' : 'after'}';
}

/// Cloudflare's published edge ranges (cloudflare.com/ips). An auth request
/// recorded with one of these means Vaultwarden sees the proxy, not the
/// client (IP_HEADER not set), and the requester may fail its same-IP check.
const _cloudflareRanges = [
  '173.245.48.0/20',
  '103.21.244.0/22',
  '103.22.200.0/22',
  '103.31.4.0/22',
  '141.101.64.0/18',
  '108.162.192.0/18',
  '190.93.240.0/20',
  '188.114.96.0/20',
  '197.234.240.0/22',
  '198.41.128.0/17',
  '162.158.0.0/15',
  '104.16.0.0/13',
  '104.24.0.0/14',
  '172.64.0.0/13',
  '131.0.72.0/22',
  '2400:cb00::/32',
  '2606:4700::/32',
  '2803:f800::/32',
  '2405:b500::/32',
  '2405:8100::/32',
  '2a06:98c0::/29',
  '2c0f:f248::/32',
];

const _privateRanges = [
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
  '100.64.0.0/10',
  'fc00::/7',
];

bool _inRange(InternetAddress a, String cidr) {
  final slash = cidr.indexOf('/');
  final net = InternetAddress(cidr.substring(0, slash));
  final bits = int.parse(cidr.substring(slash + 1));
  if (net.type != a.type) return false;
  final x = a.rawAddress;
  final y = net.rawAddress;
  for (var i = 0; i < bits; i++) {
    final mask = 0x80 >> (i % 8);
    if ((x[i ~/ 8] & mask) != (y[i ~/ 8] & mask)) return false;
  }
  return true;
}

/// What kind of address Vaultwarden recorded for the requester (the address
/// itself is not printed).
String _ipKind(String ip) {
  final a = InternetAddress.tryParse(ip);
  if (a == null) return 'not an IP address';
  if (a.isLoopback) return 'loopback';
  if (a.isLinkLocal) return 'link-local';
  if (_privateRanges.any((r) => _inRange(a, r))) return 'private network';
  if (_cloudflareRanges.any((r) => _inRange(a, r))) {
    return 'a CLOUDFLARE EDGE address: Vaultwarden sees the proxy, not the '
        'client (set IP_HEADER=CF-Connecting-IP)';
  }
  final family = a.type == InternetAddressType.IPv6 ? 'IPv6' : 'IPv4';
  return 'a public client address ($family)';
}

bool _allChecksPass(Object? checks) =>
    checks is Map &&
    checks.length == 3 &&
    const ['privateKeyDecrypts', 'publicKeyMatches', 'matchesMasterKeyUnwrap']
        .every((k) => checks[k] == true);

// ─────────────────────────────────────────────────────────────── budget guard

class _Rule {
  _Rule(this.name, this.method, String url, this.max, {this.withId = false})
      : url = Uri.parse(url);

  final String name;
  final String method;
  final Uri url;
  final int max;

  /// `url/<uuid>` instead of exactly `url`.
  final bool withId;
  int used = 0;

  bool matches(String m, Uri u) {
    if (m != method ||
        u.scheme != url.scheme ||
        u.host != url.host ||
        u.port != url.port) {
      return false;
    }
    if (!withId) return u.path == url.path;
    final prefix = '${url.path}/';
    return u.path.startsWith(prefix) &&
        _uuidPattern.hasMatch(u.path.substring(prefix.length));
  }

  @override
  String toString() => '$method ${url.path}${withId ? '/{id}' : ''} $used/$max';
}

class _Exchange {
  _Exchange(this.method, this.path);

  final String method;
  final String path;
  int? status;
  int ms = 0;
  String? error;
  bool viaCloudflare = false;
  bool html = false;

  @override
  String toString() => '$method $path → ${status ?? error} ($ms ms)';
}

class _Budget {
  _Budget(this.rules, {required this.maxHubUpgrades});

  final List<_Rule> rules;
  final int maxHubUpgrades;
  final log = <_Exchange>[];
  final refused = <String>[];
  int hubUpgrades = 0;

  _Rule? take(String method, Uri uri) {
    for (final r in rules) {
      if (!r.matches(method, uri)) continue;
      if (r.used >= r.max) return null;
      r.used++;
      return r;
    }
    return null;
  }
}

/// The app's transport for one origin (what `VaultApiService`'s per-origin
/// adapter builds: `ClientCertService.securityContextFor` →
/// `IOHttpClientAdapter(createHttpClient: httpClientFor(context))`), plus:
///  * the budget guard (refuses before any I/O),
///  * `deviceName` → "VaultApprover live test" in the password grant (the
///    app hard-codes "Vault Approver"; the test device must be recognisable),
///  * a record of each exchange (status, time, edge), never bodies or
///    credentials.
class _LiveTransport implements HttpClientAdapter {
  _LiveTransport(this.budget, this.certs, this.serverUrl);

  final _Budget budget;
  final ClientCertService certs;
  final String serverUrl;
  IOHttpClientAdapter? _inner;

  /// Non-secret fields of the password grant as sent (after the rename).
  Map<String, String>? grantForm;
  Map<String, String>? grantHeaders;

  Future<IOHttpClientAdapter> _transport() async {
    final existing = _inner;
    if (existing != null) return existing;
    final context = await certs.securityContextFor(serverUrl);
    return _inner = IOHttpClientAdapter(
      createHttpClient: () => ClientCertService.httpClientFor(context),
    );
  }

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
    final uri = options.uri;
    final label = '${options.method} ${uri.path}';
    final rule = budget.take(options.method, uri);
    if (rule == null) {
      budget.refused.add(label);
      throw StateError('live budget: refused $label (not on the list or over '
          'its count); nothing was sent');
    }
    if (rule.name == 'token') {
      final text = utf8.decode(body);
      final form = Uri.splitQueryString(text);
      if (form['grant_type'] != 'password') {
        budget.refused.add('$label grant_type=${form['grant_type']}');
        throw StateError('live budget: refused a ${form['grant_type']} grant; '
            'nothing was sent');
      }
      var renamed = false;
      final rewritten = text.split('&').map((pair) {
        if (!pair.startsWith('deviceName=')) return pair;
        renamed = true;
        return 'deviceName=${Uri.encodeQueryComponent(_deviceName)}';
      }).join('&');
      if (!renamed) throw StateError('token form without deviceName');
      body = Uint8List.fromList(utf8.encode(rewritten));
      options.headers[Headers.contentLengthHeader] = '${body.length}';
      final sent = Uri.splitQueryString(rewritten);
      grantForm = {
        for (final k in const [
          'grant_type',
          'client_id',
          'scope',
          'deviceType',
          'deviceIdentifier',
          'deviceName',
          'twoFactorProvider',
          'twoFactorRemember',
        ])
          if (sent[k] != null) k: sent[k]!,
      };
      grantHeaders = {
        for (final k in const [
          'Bitwarden-Client-Name',
          'Bitwarden-Client-Version',
          'Device-Type',
        ])
          k: '${jsonGet(options.headers, k)}',
      };
    }
    final ex = _Exchange(options.method, uri.path);
    budget.log.add(ex);
    final sw = Stopwatch()..start();
    final ResponseBody response;
    try {
      response = await (await _transport()).fetch(
        options,
        requestStream == null ? null : Stream.value(body),
        cancelFuture,
      );
    } catch (e) {
      ex
        ..error = '${e.runtimeType}'
        ..ms = sw.elapsedMilliseconds;
      rethrow;
    }
    final h = response.headers;
    ex
      ..status = response.statusCode
      ..ms = sw.elapsedMilliseconds
      ..viaCloudflare = h['cf-ray'] != null ||
          (h['server']?.join(',').toLowerCase() == 'cloudflare')
      ..html = (h['content-type']?.join(',') ?? '').contains('text/html');
    return response;
  }

  @override
  void close({bool force = false}) => _inner?.close(force: force);
}

/// The hub's WebSocket factory: `NotificationService._defaultChannel` (client
/// certificate of the origin via `ClientCertService.createHttpClient`) plus
/// the upgrade budget and a record of each upgrade (never the token).
class _HubChannels {
  _HubChannels(this.budget, this.certs);

  final _Budget budget;
  final ClientCertService certs;
  final urls = <String>[];
  final upgrades = <String>[];

  Future<WebSocketChannel> call(Uri uri) async {
    budget.hubUpgrades++;
    final n = budget.hubUpgrades;
    urls.add('${uri.scheme}://${uri.authority}${uri.path}');
    if (n > budget.maxHubUpgrades) {
      budget.refused.add('WSS ${uri.path} upgrade #$n');
      throw StateError('live budget: hub upgrade #$n refused locally');
    }
    HttpClient? client;
    try {
      final origin = Uri(
        scheme: uri.scheme == 'wss' ? 'https' : 'http',
        host: uri.host,
        port: uri.port,
      );
      client = await certs.createHttpClient(origin.toString());
    } catch (_) {
      client = null;
    }
    final sw = Stopwatch()..start();
    final channel = IOWebSocketChannel.connect(
      uri,
      customClient: client,
      pingInterval: const Duration(seconds: 30),
      connectTimeout: const Duration(seconds: 15),
    );
    channel.ready.then<void>(
      (_) {
        upgrades.add('#$n 101 in ${sw.elapsedMilliseconds} ms');
        client?.close();
      },
      onError: (Object e) {
        Object? inner = e;
        if (e is WebSocketChannelException) inner = e.inner ?? e;
        final status =
            inner is WebSocketException ? inner.httpStatusCode : null;
        upgrades.add('#$n failed after ${sw.elapsedMilliseconds} ms: '
            '${status == null ? inner.runtimeType : 'HTTP $status'}');
        client?.close(force: true);
      },
    );
    return channel;
  }
}

// ─────────────────────────────────────────────────────────────── requester

final _liveRequesters = <_Requester>[];

/// The requester's environment: only what Python needs, the account in the
/// harness's `VA_E2E_*` slots (never on the command line), its state under
/// test/live/.state, and the live server's TLS settings.
Map<String, String> _requesterEnv(String base) {
  const passThrough = [
    'PATH',
    'HOME',
    'TMPDIR',
    'TEMP',
    'TMP',
    'LANG',
    'LC_ALL',
    'LC_CTYPE',
    'USER',
    'LOGNAME',
    'SYSTEMROOT',
    'SSL_CERT_FILE',
    'SSL_CERT_DIR',
    'REQUESTS_CA_BUNDLE',
    'CURL_CA_BUNDLE',
    'HTTP_PROXY',
    'HTTPS_PROXY',
    'NO_PROXY',
    'ALL_PROXY',
    'http_proxy',
    'https_proxy',
    'no_proxy',
    'all_proxy',
  ];
  final parent = Platform.environment;
  final mtls = _clientCrt != null && _clientKey != null;
  return {
    for (final k in passThrough)
      if (parent[k] != null) k: parent[k]!,
    'PYTHONUNBUFFERED': '1',
    'PYTHONDONTWRITEBYTECODE': '1',
    'VA_E2E_STATE_DIR': _requesterStateDir,
    // A private CA, else a path that cannot exist: e2e_config.tls_kwargs()
    // then uses the system trust store instead of tool/e2e/.pki/ca.pem.
    'VA_E2E_CA_PEM': _caPem ?? '/dev/null/no-private-ca.pem',
    'VA_E2E_MTLS_BASE': mtls ? base : 'https://mtls.invalid',
    if (mtls) 'VA_E2E_CLIENT_CRT': _clientCrt!,
    if (mtls) 'VA_E2E_CLIENT_KEY': _clientKey!,
    // requester.py --account pbkdf2|totp is only a slot name: the KDF comes
    // from the server's prelogin.
    if (_totpSecret == null) ...{
      'VA_E2E_PBKDF2_EMAIL': _email!,
      'VA_E2E_PBKDF2_PASSWORD': _password!,
    } else ...{
      'VA_E2E_TOTP_EMAIL': _email!,
      'VA_E2E_TOTP_PASSWORD': _password!,
      'VA_E2E_TOTP_SECRET': _totpSecret!,
    },
  };
}

/// tool/e2e/requester.py --json as a subprocess (as in the e2e suite).
class _Requester {
  _Requester._(this.process, this.startedAt);

  final Process process;
  final DateTime startedAt;
  final events = <Map<String, dynamic>>[];
  final eventTimes = <String, DateTime>{};
  final _stderr = StringBuffer();
  final _other = StringBuffer();
  int? exitCode;

  static Future<_Requester> start(String base, List<String> args) async {
    final process = await Process.start(
      _python,
      [
        'requester.py',
        '--json',
        '--base',
        base,
        '--account',
        _totpSecret == null ? 'pbkdf2' : 'totp',
        '--device-type',
        '$_requesterDeviceType',
        '--device-name',
        _requesterDeviceName,
        '--poll',
        '2',
        ...args,
      ],
      workingDirectory: _toolDir,
      environment: _requesterEnv(base),
      includeParentEnvironment: false,
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

  /// What went wrong on the requester side (redacted when printed).
  String get diagnostics {
    final last = events.lastOrNull;
    final hint = switch (exitCode) {
      1 => 'requester error',
      2 => 'approved, but its key checks failed',
      3 => 'saw the request denied or gone; after an approve this usually '
          'means Vaultwarden saw another client IP (proxy without IP_HEADER)',
      4 => 'no answer before its timeout',
      5 => 'auth-request login rejected (5-minute window, client IP, 2FA)',
      _ => null,
    };
    final lastText = last == null
        ? '-'
        : '${last['event']}'
            '${last['message'] == null ? '' : ': ${last['message']}'}';
    return 'requester exit ${exitCode ?? '(running)'}'
        '${hint == null ? '' : ' ($hint)'}; last event $lastText'
        '${_other.isEmpty ? '' : '; stdout: ${_oneLine('$_other', 300)}'}'
        '${_stderr.isEmpty ? '' : '; stderr: ${_oneLine('$_stderr', 600)}'}';
  }

  /// Waits for [name]; fails fast on a terminal event of another kind or
  /// when the process exits without it.
  Future<Map<String, dynamic>> event(
    String name, {
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      for (final e in events) {
        if (e['event'] == name) return e;
        if (e['event'] != 'created' && e['event'] != 'answered') {
          fail('requester: "${e['event']}" instead of "$name": $diagnostics');
        }
      }
      if (exitCode != null) {
        fail('requester exited without "$name": $diagnostics');
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('requester: no "$name" within ${timeout.inSeconds} s: '
            '$diagnostics');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<int> exit({Duration timeout = const Duration(seconds: 30)}) =>
      process.exitCode.timeout(timeout, onTimeout: () {
        process.kill();
        fail('requester did not exit: $diagnostics');
      });

  void kill() {
    if (exitCode == null) process.kill();
  }
}

// ─────────────────────────────────────────────────────────────── the run

class _StepFailed implements Exception {
  const _StepFailed();
}

class _Run {
  final failures = <String>[];

  Future<T> step<T>(String id, String title, Future<T> Function() body) async {
    final sw = Stopwatch()..start();
    try {
      final result = await body();
      _log('PASS  $id  $title (${sw.elapsedMilliseconds} ms)');
      return result;
    } on _StepFailed {
      rethrow;
    } catch (e) {
      final msg = _describe(e);
      _log('FAIL  $id  $title: $msg');
      failures.add('$id $title: $msg');
      throw const _StepFailed();
    }
  }

  void info(String text) => _log('        $text');
}

void _check(bool ok, String what) {
  if (!ok) fail(what);
}

Future<void> _runLive(_Run run) async {
  final base = ServerEnvironment.fromUrl(_base!).baseUrl;
  final env = ServerEnvironment.fromUrl(base);
  final baseUri = Uri.parse(base);
  final email = _email!;
  final password = _password!;
  _secret(password);
  _secret(_totpSecret);
  _secret(_p12Pass);

  final (deviceId, _) = await run.step('0', 'configuration', () async {
    _check(!env.isCloud,
        'self-hosted Vaultwarden only (Bitwarden cloud has other hosts)');
    _check(!ServerEnvironment.isPlaintextRemote(base),
        'refusing to send credentials over plain http:// to a remote host');
    _check(File('$_toolDir/requester.py').existsSync(),
        'tool/e2e/requester.py not found (run from the repository root)');
    if (_p12 != null || _clientCrt != null || _clientKey != null) {
      _check(_p12 != null && _p12Pass != null,
          'mTLS: set VA_LIVE_P12 and VA_LIVE_P12_PASS for the app');
      _check(
          _clientCrt != null && _clientKey != null,
          'mTLS: set VA_LIVE_CLIENT_CRT and VA_LIVE_CLIENT_KEY (PEM of the '
          'same identity) for the requester');
    }
    final deps = await Process.run(
      _python,
      ['-c', 'import requests, cryptography, argon2'],
      environment: {'PYTHONDONTWRITEBYTECODE': '1'},
    );
    _check(
        deps.exitCode == 0,
        'requester python $_python lacks tool/e2e/requirements.txt (see '
        'tool/e2e/README.md): ${_oneLine('${deps.stderr}', 200)}');
    final (id, created) = _loadOrCreateDeviceId();
    final port = baseUri.hasPort ? ':${baseUri.port}' : '';
    final tls = [
      baseUri.scheme,
      if (_p12 != null) 'client certificate',
      if (_caPem != null) 'private CA',
    ].join(' + ');
    run
      ..info('server ${baseUri.host}$port ($tls), account '
          '${_maskEmail(email)}${_totpSecret != null ? ' (TOTP)' : ''}')
      ..info('app device "$_deviceName" ${id.substring(0, 8)}… '
          '(${created ? 'NEW, saved to' : 'reused from'} '
          'test/live/.device_id); requester python $_python');
    return (id, created);
  });

  FlutterSecureStorage.setMockInitialValues(
      {SecureStorageService.keyDeviceId: deviceId});
  final storage = SecureStorageService();
  final certs = ClientCertService();
  final crypto = CryptoService();
  final budget = _Budget([
    _Rule('version', 'GET', '${env.apiUrl}/version', 1),
    _Rule('prelogin', 'POST', '${env.identityUrl}/accounts/prelogin', 1),
    _Rule('token', 'POST', '${env.identityUrl}/connect/token', 1),
    _Rule('pending', 'GET', '${env.apiUrl}/auth-requests/pending',
        2 * _pendingPolls + 2),
    _Rule('respond', 'PUT', '${env.apiUrl}/auth-requests', 2, withId: true),
    _Rule('devices', 'GET', '${env.apiUrl}/devices', 1),
    _Rule('now', 'GET', '${env.apiUrl}/now', 1),
  ], maxHubUpgrades: 2);
  final transport = _LiveTransport(budget, certs, base);
  final api = VaultApiService(
    storage,
    clientCerts: certs,
    crypto: crypto,
    httpClientAdapter: transport,
    deviceType: _deviceType,
  );
  // For the two calls the app has no method for (version, devices): the
  // app's BaseOptions and headers over the same guarded transport.
  final raw = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    headers: VaultApiService.defaultHeaders(_deviceType),
    followRedirects: false,
  ))
    ..httpClientAdapter = _LiveTransport(budget, certs, base);
  final hubChannels = _HubChannels(budget, certs);
  final hubEvents = <(DateTime, HubEvent)>[];
  NotificationService? hub;
  Uint8List? userKey;
  final unanswered = <String>{};

  // A test timeout skips `finally`: never leave a requester or socket behind.
  addTearDown(() {
    for (final r in _liveRequesters) {
      r.kill();
    }
    _liveRequesters.clear();
    hub?.reset();
  });

  Future<(DateTime, HubEvent)> waitHub(
    bool Function(HubEvent e) test, {
    required DateTime from,
    required String what,
  }) {
    final left = from.add(_hubDeadline).difference(DateTime.now());
    return _poll(
      () async {
        for (final entry in hubEvents) {
          if (test(entry.$2)) return entry;
        }
        return null;
      },
      timeout: left.isNegative ? Duration.zero : left,
      interval: const Duration(milliseconds: 50),
      what: () => '$what (hub ${hub?.state.name}, upgrades '
          '${hubChannels.upgrades.join(', ')})',
    );
  }

  Future<AuthRequest> waitPending(String id) async {
    for (var i = 1; i <= _pendingPolls; i++) {
      final list = await api.getPendingRequests();
      final hit = list.where((r) => r.id == id).firstOrNull;
      if (hit != null) {
        run.info('GET /pending listed it on poll $i/$_pendingPolls; server '
            'clock offset ${_ms(api.serverClockOffset)}');
        return hit;
      }
      if (i < _pendingPolls) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    fail('auth request not in GET /api/auth-requests/pending after '
        '$_pendingPolls polls');
  }

  void checkRequest(AuthRequest r, Map<String, dynamic> created) {
    _check(r.fingerprint != null, 'the app computed no fingerprint phrase');
    _check(
        r.fingerprint == created['fingerprint'],
        'fingerprint phrase mismatch: app "${r.fingerprint}" vs requester '
        '(Bitwarden algorithm) "${created['fingerprint']}"');
    _check(r.isActionable, 'the app does not treat it as actionable');
    // Server clock via `Date` (1-s resolution, possibly set by the proxy):
    // allow some skew above 5 minutes; "fresh" is what matters.
    final left = r.remaining();
    _check(
        left > const Duration(minutes: 4) &&
            left <= const Duration(minutes: 5, seconds: 30),
        'remaining ${left.inSeconds} s is outside (240, 330] s (server clock '
        'offset ${_ms(api.serverClockOffset)})');
    run.info('fingerprint phrase "${r.fingerprint}" == requester; '
        'actionable, ${left.inSeconds} s left; requester type '
        '"${r.requestDeviceType}", IP is ${_ipKind(r.requestIpAddress)}');
  }

  try {
    // ── TLS material (mTLS / private CA only; no request) ──
    if (_p12 != null || _caPem != null) {
      await run.step('0b', 'client certificate / CA for this origin', () async {
        final ca = _caPem;
        if (ca != null) {
          await certs.setTrustedCaPem(base, File(ca).readAsStringSync());
        }
        final p12 = _p12;
        if (p12 != null) {
          final info = await certs.importCertificate(
            serverUrl: base,
            pkcs12: File(p12).readAsBytesSync(),
            password: _p12Pass!,
          );
          _check(!info.isExpired(), 'the client certificate has expired');
          run.info('client certificate "${info.commonName}", notAfter '
              '${info.notAfter?.toIso8601String()}');
        }
      });
    }

    // ── 1. server version ──
    await run.step('1', 'GET /api/version', () async {
      try {
        final res = await raw.get<dynamic>('${env.apiUrl}/version');
        final v = res.data;
        run.info('server version ${v is String ? v : jsonEncode(v)}; via '
            'Cloudflare ${budget.log.last.viaCloudflare ? 'yes' : 'no'}');
      } on DioException catch (e) {
        if (e.error is StateError) rethrow; // budget guard
        // Informational only: some servers hide it.
        run.info('server version not available '
            '(${e.response?.statusCode ?? e.type.name})');
      }
    });

    // ── 2. prelogin ──
    final kdf = await run.step('2', 'prelogin (KDF parameters)', () async {
      final k = await api.prelogin(base, email);
      k.validate(); // F15 minimums / sanity maxima
      run.info('$k, validate() OK');
      return k;
    });

    // ── 3. one password grant, like SessionNotifier.setup ──
    final session = await run.step('3', 'password login (1 grant)', () async {
      final sw = Stopwatch()..start();
      final keys = await crypto.deriveLoginKeys(email, password, kdf);
      final kdfMs = sw.elapsedMilliseconds;
      _secret(keys.masterPasswordHashB64);
      String? code;
      final totpSecret = _totpSecret;
      if (totpSecret != null) {
        code = _totp(totpSecret, _currentStep());
        _secret(code);
      }
      final Map<String, dynamic> json;
      try {
        json = await api.login(
          serverUrl: base,
          email: email,
          masterPasswordHashB64: keys.masterPasswordHashB64,
          deviceId: deviceId,
          twoFactorToken: code,
          twoFactorProvider: code == null ? null : 0,
          twoFactorRemember: false, // no remember token for this device
        );
      } on TwoFactorRequiredException catch (e) {
        keys.wipe();
        fail('the account needs two-step login (providers '
            '${e.availableProviders}); only authenticator (TOTP) is '
            'supported: set VA_LIVE_TOTP_SECRET');
      } on InvalidTwoFactorCodeException {
        keys.wipe();
        fail('TOTP code rejected (wrong secret, clock skew, or this 30-s code '
            'was already used: wait a minute and run again)');
      } catch (_) {
        keys.wipe();
        rethrow;
      }
      final grant = budget.log.last;
      final token = TokenResponse.fromJson(json);
      _secret(token.accessToken);
      _secret(token.refreshToken);
      _secret(token.key);
      _secret(token.privateKey);
      _secret(token.twoFactorToken);
      final refresh = token.refreshToken;
      _check(refresh != null, 'token response without refresh_token');
      final protected = CipherString.parse(token.requireProtectedUserKey());
      final unlockKdf = token.masterPasswordUnlock?.kdf;
      final sameKdf = unlockKdf == null ||
          (unlockKdf.sameKdfAs(kdf) &&
              unlockKdf.saltFor(email) == kdf.saltFor(email));
      try {
        if (sameKdf) {
          userKey =
              crypto.decryptUserKeyWithMasterKey(protected, keys.masterKey);
        } else {
          final mk = await crypto.deriveMasterKey(email, password, unlockKdf);
          try {
            userKey = crypto.decryptUserKeyWithMasterKey(protected, mk);
          } finally {
            mk.fillRange(0, mk.length, 0);
          }
        }
      } finally {
        keys.wipe();
      }
      _check(userKey!.length == 64, 'user key is ${userKey!.length} bytes');
      _secret(base64Encode(userKey!));
      final s = UserSession(
        email: email.trim(),
        serverUrl: base,
        accessToken: token.accessToken,
        refreshToken: refresh!,
        accessTokenExpiry: token.expiryFrom(DateTime.now()),
      );
      await storage.saveSession(s); // mocked keychain, memory only
      api.configure(base, s);
      final form = transport.grantForm ?? const {};
      final headers = transport.grantHeaders ?? const {};
      _check(form['deviceName'] == _deviceName,
          'deviceName sent "${form['deviceName']}"');
      _check(form['deviceIdentifier'] == deviceId, 'deviceIdentifier differs');
      _check(form['deviceType'] == _deviceType && form['client_id'] == 'mobile',
          'deviceType/client_id ${form['deviceType']}/${form['client_id']}');
      _check(
          headers['Bitwarden-Client-Name'] == kBitwardenClientName &&
              headers['Bitwarden-Client-Version'] == kBitwardenClientVersion &&
              headers['Device-Type'] == _deviceType,
          'client headers $headers');
      _check(token.twoFactorToken == null,
          'the server issued a 2FA remember token although remember=0');
      run
        ..info('KDF $kdfMs ms; token HTTP ${grant.status} in ${grant.ms} ms, '
            'expires_in ${token.expiresIn} s; user key decrypted (64 bytes, '
            'MAC verified)')
        ..info('sent deviceName "${form['deviceName']}", deviceType '
            '${form['deviceType']}, client '
            '${headers['Bitwarden-Client-Name']}/'
            '${headers['Bitwarden-Client-Version']}'
            '${code == null ? '' : ', TOTP (provider 0, remember 0)'}');
      return s;
    });

    // ── 4. hub with the real token ──
    await run.step('4', 'notifications hub connects', () async {
      final h = hub = NotificationService(
        tokenProvider: ({bool forceRefresh = false}) =>
            api.getValidAccessToken(forceRefresh: forceRefresh),
        clientCerts: certs,
        channelFactory: hubChannels.call,
        initialBackoff: const Duration(seconds: 1),
        maxBackoff: const Duration(seconds: 2),
      );
      h.events.listen((e) => hubEvents.add((DateTime.now(), e)));
      final sw = Stopwatch()..start();
      await h.connectEnvironment(env);
      await _poll(
        () async => h.isConnected ? true : null,
        timeout: const Duration(seconds: 20),
        what: () => 'hub handshake (state ${h.state.name}, upgrades '
            '${hubChannels.upgrades.join(', ')})',
      );
      final hubUri = env.hubUri();
      final expected = '${hubUri.scheme}://${hubUri.authority}${hubUri.path}';
      _check(hubChannels.urls.first == expected,
          'hub dialled ${hubChannels.urls.first}, expected $expected');
      _check(session.accessToken == api.session?.accessToken,
          'the session changed while connecting');
      run.info('$expected connected in ${sw.elapsedMilliseconds} ms '
          '(${hubChannels.upgrades.join(', ')})');
    });

    // ── 5–8. request #1: hub → /pending → phrase → approve ──
    final registered = _requesterRegistered(base, email);
    final req1 = await _Requester.start(base, ['--timeout', '90']);
    final (id1, created1) =
        await run.step('5', 'requester creates request #1', () async {
      final created =
          await req1.event('created', timeout: const Duration(seconds: 60));
      final id = created['id'] as String;
      unanswered.add(id);
      final after = req1.eventTimes['created']!.difference(req1.startedAt);
      run.info('request ${id.substring(0, 8)}… created ${_ms(after)} after '
          'the requester started'
          '${registered ? '' : ' (first run: it registered its device with '
              'one password login)'}');
      return (id, created);
    });

    await run
        .step('6', 'hub delivers Type 15 within ${_hubDeadline.inSeconds} s',
            () async {
      final createdAt = req1.eventTimes['created']!;
      final (at, event) = await waitHub(
        (e) => e.isAuthRequest && e.authRequestId == id1,
        from: createdAt,
        what: 'hub Type 15 for request #1',
      );
      run.info('Type ${event.type} arrived ${_rel(at.difference(createdAt))} '
          'the requester printed "created" '
          '(${_ms(at.difference(req1.startedAt))} after it started)');
    });

    final r1 =
        await run.step('7', 'GET /pending lists #1, phrase matches', () async {
      final r = await waitPending(id1);
      checkRequest(r, created1);
      return r;
    });

    await run.step('8', 'approve #1 → requester decrypts and logs in',
        () async {
      final encrypted =
          crypto.encryptUserKeyForApproval(userKey!, r1.publicKey);
      _secret(encrypted);
      final approvedAt = DateTime.now();
      await api.respondToAuthRequest(
        requestId: id1,
        approved: true,
        encryptedKey: encrypted,
        deviceId: deviceId,
      );
      unanswered.remove(id1);
      final put = budget.log.last;
      run.info('PUT approve → HTTP ${put.status} in ${put.ms} ms');
      final answered =
          await req1.event('answered', timeout: const Duration(seconds: 30));
      _check(
          answered['keyType'] == '4',
          'requester got key type ${answered['keyType']} (expected 4 = '
          'RSA-OAEP-SHA1)');
      _check(answered['masterPasswordHash'] == null,
          'requester got a masterPasswordHash');
      final verified =
          await req1.event('verified', timeout: const Duration(seconds: 60));
      final exit = await req1.exit();
      _check(exit == 0, 'requester exit $exit: ${req1.diagnostics}');
      _check(_allChecksPass(verified['checks']),
          'requester checks ${verified['checks']}');
      final type16 = hubEvents
          .where((e) => e.$2.isAuthRequestResponse && e.$2.authRequestId == id1)
          .firstOrNull;
      run
        ..info('requester: key type 4, masterPasswordHash null, decrypted '
            'the user key, logged in with the auth request; checks '
            '${verified['checks']}; done '
            '${_ms(DateTime.now().difference(approvedAt))} after the PUT')
        ..info('hub Type 16 after the approve: ${type16 == null ? 'not seen '
            '(informational)' : 'yes, ${_ms(type16.$1.difference(approvedAt))}'
            ' after the PUT'}');
    });

    // ── 9–11. request #2: hub → /pending → deny ──
    final req2 =
        await _Requester.start(base, ['--timeout', '60', '--expect', 'deny']);
    final (id2, created2) =
        await run.step('9', 'requester creates request #2', () async {
      final created =
          await req2.event('created', timeout: const Duration(seconds: 60));
      final id = created['id'] as String;
      unanswered.add(id);
      return (id, created);
    });

    final r2 =
        await run.step('10', 'hub Type 15 + GET /pending list #2', () async {
      final createdAt = req2.eventTimes['created']!;
      final (at, _) = await waitHub(
        (e) => e.isAuthRequest && e.authRequestId == id2,
        from: createdAt,
        what: 'hub Type 15 for request #2',
      );
      run.info('Type 15 arrived ${_rel(at.difference(createdAt))} the '
          'requester printed "created"');
      final r = await waitPending(id2);
      checkRequest(r, created2);
      return r;
    });

    await run.step('11', 'deny #2 → requester sees it denied', () async {
      await api.respondToAuthRequest(
        requestId: r2.id,
        approved: false,
        deviceId: deviceId,
      );
      unanswered.remove(id2);
      run.info('PUT deny → HTTP ${budget.log.last.status}');
      final denied =
          await req2.event('denied', timeout: const Duration(seconds: 30));
      final exit = await req2.exit();
      _check(exit == 0, 'requester exit $exit: ${req2.diagnostics}');
      final list = await api.getPendingRequests(includeExpired: true);
      _check(
          !list.any((r) => r.id == id2), 'the denied request is still listed');
      run.info('requester: "${denied['message']}"; no longer in /pending');
    });

    // ── 12. one device row for this test device ──
    await run.step('12', 'GET /api/devices: one row for this device', () async {
      final res = await raw.get<dynamic>(
        '${env.apiUrl}/devices',
        options: Options(
            headers: {'Authorization': 'Bearer ${api.session!.accessToken}'}),
      );
      final data = jsonGet(res.data, 'data');
      _check(data is List, 'unexpected /api/devices body');
      final rows =
          (data as List).map(asJsonMap).whereType<Map<String, dynamic>>();
      final mine = rows.where((d) => jsonString(d, 'identifier') == deviceId);
      _check(mine.length == 1, '${mine.length} rows with our identifier');
      _check(jsonString(mine.single, 'name') == _deviceName,
          'our row is named "${jsonString(mine.single, 'name')}"');
      final named = rows.where((d) => jsonString(d, 'name') == _deviceName);
      final requesters =
          rows.where((d) => jsonString(d, 'name') == _requesterDeviceName);
      run.info('"$_deviceName": ${named.length} row(s); '
          '"$_requesterDeviceName": ${requesters.length} row(s); '
          '${rows.length} devices in total');
    });
  } on _StepFailed {
    // reported by the caller
  } finally {
    for (final r in _liveRequesters) {
      r.kill();
    }
    _liveRequesters.clear();
    // A request a failed step left unanswered is denied (deleted) rather
    // than left pending on the account's other devices.
    for (final id in unanswered) {
      try {
        await api.respondToAuthRequest(
            requestId: id, approved: false, deviceId: deviceId);
        _log('cleanup: denied the unanswered request ${id.substring(0, 8)}…');
      } catch (e) {
        _log('cleanup: could not deny ${id.substring(0, 8)}…: '
            '${_describe(e)}');
      }
    }
    try {
      await run.step('13', 'stop the hub, reset services', () async {
        final h = hub;
        final before = budget.hubUpgrades;
        if (h != null) {
          h.reset();
          await Future<void>.delayed(const Duration(milliseconds: 1500));
          _check(h.state == HubConnectionState.disconnected,
              'hub state ${h.state.name} after reset');
          _check(budget.hubUpgrades == before, 'hub reconnected after reset');
          h.dispose();
          hub = null;
        }
        api
          ..reset()
          ..dispose();
        raw.close(force: true);
        certs.dispose();
        final key = userKey;
        key?.fillRange(0, key.length, 0);
        FlutterSecureStorage.setMockInitialValues({});
        run.info('hub ${h == null ? 'never started' : 'disconnected after '
                '${budget.hubUpgrades} upgrade(s)'}; session, keys and mocked '
            'keychain cleared');
      });
    } on _StepFailed {
      // reported by the caller
    }
    final used = budget.rules.where((r) => r.used > 0).join(', ');
    _log('budget: ${budget.log.length} HTTP request(s) [$used], '
        '${budget.hubUpgrades} hub upgrade(s), refused '
        '${budget.refused.isEmpty ? 'none' : budget.refused.join(', ')}');
    final cf = budget.log.where((e) => e.viaCloudflare).length;
    final html = budget.log.where((e) => e.html).toList();
    _log('edge: $cf/${budget.log.length} responses via Cloudflare'
        '${html.isEmpty ? '' : '; HTML (block/challenge page?): $html'}');
    if (budget.refused.isNotEmpty) {
      run.failures.add('budget: refused ${budget.refused.join(', ')}');
    }
  }
}

// ─────────────────────────────────────────────────────────────── main

void main() {
  final configured = _base != null && _email != null && _password != null;

  group('live auth (real server, real account)', () {
    test('login → hub → auth request approve + deny', () async {
      final run = _Run();
      try {
        await _runLive(run);
      } on _StepFailed {
        // already recorded
      } catch (e) {
        // Anything outside a step, never printed unredacted.
        run.failures.add('unexpected: ${_describe(e)}');
      }
      _log(run.failures.isEmpty
          ? 'RESULT PASS'
          : 'RESULT FAIL (${run.failures.length})');
      if (run.failures.isNotEmpty) fail(_redact(run.failures.join('\n')));
    });
  },
      skip: configured
          ? false
          : 'live auth test: set VA_LIVE_BASE, VA_LIVE_EMAIL and '
              'VA_LIVE_PASSWORD (see test/live/README.md)');
}
