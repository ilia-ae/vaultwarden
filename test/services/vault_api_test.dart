import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/models/user_session.dart';
import 'package:vault_approver/services/secure_storage_service.dart';
import 'package:vault_approver/services/vault_api.dart';
import 'package:vault_approver/utils/constants.dart';

import 'rsa_fixture.dart';

const _sdkPublicKey =
    'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvyLRDUwXB4BfQ507D4meFPmwn5zwy3IqTPJO4plrrhnclWahXa240BzyFW9gHgYu+Jrgms5xBfRTBMcEsqqNm7+JpB6C1B6yvnik0DpJgWQw1rwvy4SUYidpR/AWbQi47n/hvnmzI/sQxGddVfvWu1iTKOlf5blbKYAXnUE5DZBGnrWfacNXwRRdtP06tFB0LwDgw+91CeLSJ9py6dm1qX5JIxoO8StJOQl65goLCdrTWlox+0Jh4xFUfCkb+s3px+OhSCzJbvG/hlrSRcUz5GnwlCEyF3v5lfUtV96MJD+78d8pmH6CfFAp2wxKRAbGdk+JccJYO6y6oIXd3Fm7twIDAQAB';

const _base = 'https://vault.example.com:8443';

typedef _Handler = FutureOr<ResponseBody> Function(RequestOptions o);

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  _Handler handler;
  final requests = <RequestOptions>[];

  List<String> get urls => requests.map((r) => '${r.method} ${r.uri}').toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (requestStream != null) await requestStream.drain<void>();
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

/// Like a real server, responses carry a `Date` header unless [date] is
/// false.
ResponseBody _json(
  int status,
  Object? body, {
  Map<String, List<String>> headers = const {},
  bool date = true,
}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        if (date) 'date': [HttpDate.format(DateTime.now())],
        ...headers,
      },
    );

Map<String, dynamic> _vwError(String message) => {
      'message': message,
      'errorModel': {'message': message, 'object': 'error'},
      'error': '',
      'error_description': '',
      'object': 'error',
    };

Map<String, dynamic> _item(
  String id, {
  String? publicKey = _sdkPublicKey,
  DateTime? created,
  bool? approved,
  String? responseDate,
  String? device,
}) =>
    {
      'id': id,
      'publicKey': publicKey,
      'requestDeviceType': 'Chrome',
      'requestIpAddress': '192.0.2.10',
      'creationDate': (created ?? DateTime.now().toUtc()).toIso8601String(),
      'responseDate': responseDate,
      'requestApproved': approved,
      if (device != null) 'requestDeviceIdentifier': device,
    };

UserSession _session({
  String serverUrl = _base,
  Duration expiresIn = const Duration(hours: 1),
  String refreshToken = 'rt',
  String accessToken = 'at',
}) =>
    UserSession(
      email: 'test@bitwarden.com',
      serverUrl: serverUrl,
      accessToken: accessToken,
      refreshToken: refreshToken,
      accessTokenExpiry: DateTime.now().add(expiresIn),
    );

void main() {
  late _FakeAdapter adapter;
  late VaultApiService api;
  late SecureStorageService storage;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = SecureStorageService();
    adapter = _FakeAdapter((o) => _json(200, {}));
    api = VaultApiService(
      storage,
      httpClientAdapter: adapter,
      deviceType: '1',
    );
  });

  tearDown(() => api.dispose());

  group('headers (F2)', () {
    test('every request carries client name/version and device type', () async {
      adapter.handler = (o) {
        if (o.path.endsWith('/prelogin')) {
          return _json(200, {'kdf': 0, 'kdfIterations': 600000});
        }
        if (o.path.endsWith('/connect/token')) {
          return _json(200, {'access_token': 'at', 'expires_in': 3600});
        }
        return _json(200, {'data': []});
      };
      await api.prelogin(_base, 'a@b.com');
      await api.login(
        serverUrl: _base,
        email: 'a@b.com',
        masterPasswordHashB64: 'hash',
        deviceId: 'dev',
      );
      api.configure(_base, _session());
      await api.getPendingRequests();
      await api.respondToAuthRequest(
        requestId: 'r',
        approved: false,
        deviceId: 'dev',
      );
      expect(adapter.requests, hasLength(4));
      for (final r in adapter.requests) {
        expect(r.headers['Bitwarden-Client-Name'], 'mobile', reason: r.path);
        expect(r.headers['Bitwarden-Client-Version'], '2026.9.0');
        expect(r.headers['Device-Type'], '1');
      }
      expect(kBitwardenClientVersion, '2026.9.0');
    });
  });

  group('identity', () {
    test('prelogin URL (self-hosted keeps port) and parsed salt', () async {
      adapter.handler = (o) => _json(200, {
            'kdf': 1,
            'kdfIterations': 3,
            'kdfMemory': 64,
            'kdfParallelism': 4,
            'salt': 'Salt@Example.com',
          });
      final kdf = await api.prelogin('$_base/', ' a@b.com ');
      expect(adapter.urls.single, 'POST $_base/identity/accounts/prelogin');
      expect(adapter.requests.single.data, {'email': 'a@b.com'});
      expect(kdf.isArgon2id, isTrue);
      expect(kdf.salt, 'Salt@Example.com');
    });

    test('cloud uses identity.bitwarden.com (F16)', () async {
      adapter.handler = (o) => _json(200, {'kdf': 0, 'kdfIterations': 600000});
      await api.prelogin('https://vault.bitwarden.com', 'a@b.com');
      expect(
        adapter.urls.single,
        'POST https://identity.bitwarden.com/accounts/prelogin',
      );
    });

    test('password grant form incl. 2FA and new-device OTP', () async {
      adapter.handler = (o) => _json(200, {'access_token': 'at'});
      await api.login(
        serverUrl: _base,
        email: ' a@b.com ',
        masterPasswordHashB64: 'hash',
        deviceId: 'dev-id',
        twoFactorToken: 'remember',
        twoFactorProvider: 5,
        newDeviceOtp: ' 123456 ',
      );
      final r = adapter.requests.single;
      expect(r.uri.toString(), '$_base/identity/connect/token');
      expect(r.contentType, Headers.formUrlEncodedContentType);
      expect(r.data, {
        'grant_type': 'password',
        'username': 'a@b.com',
        'password': 'hash',
        'scope': 'api offline_access',
        'client_id': 'mobile',
        'deviceType': '1',
        'deviceIdentifier': 'dev-id',
        'deviceName': 'Vault Approver',
        'twoFactorToken': 'remember',
        'twoFactorProvider': '5',
        'twoFactorRemember': '1',
        'newDeviceOtp': '123456',
      });
    });

    test('typed login errors (F9)', () async {
      final cases = <Object, Matcher>{
        _vwError('Username or password is incorrect. Try again'):
            isA<InvalidCredentialsException>(),
        {
          'error': 'invalid_grant',
          'error_description': 'Two factor required.',
          'TwoFactorProviders': ['0', '1'],
          'TwoFactorProviders2': {'0': null, '1': null},
        }: isA<TwoFactorRequiredException>(),
        _vwError('Invalid TOTP code! Server time: x IP: y'):
            isA<InvalidTwoFactorCodeException>(),
        {
          'error': 'device_error',
          'error_description': 'New device verification required',
          'ErrorModel': {'Message': 'new device verification required'},
        }: isA<NewDeviceVerificationRequiredException>(),
        {
          'error': 'device_error',
          'error_description': 'Invalid New Device OTP',
          'ErrorModel': {'Message': 'invalid new device otp'},
        }: isA<InvalidNewDeviceOtpException>(),
        _vwError('This user has been disabled'): isA<ServerException>(),
      };
      for (final entry in cases.entries) {
        adapter.handler = (o) => _json(400, entry.key);
        await expectLater(
          api.login(
            serverUrl: _base,
            email: 'a@b.com',
            masterPasswordHashB64: 'h',
            deviceId: 'd',
          ),
          throwsA(entry.value),
          reason: '${entry.key}',
        );
      }
      adapter.handler = (o) => _json(429, _vwError('Too many login requests'));
      await expectLater(
        api.prelogin(_base, 'a@b.com'),
        throwsA(isA<RateLimitedException>()),
      );
    });

    test('send-email-login and resend-new-device-otp (F12, F6)', () async {
      adapter.handler = (o) => _json(200, null);
      await api.sendEmailLoginCode(
        serverUrl: 'https://vault.bitwarden.eu',
        email: 'a@b.com',
        masterPasswordHashB64: 'h',
        deviceId: 'dev',
      );
      await api.resendNewDeviceOtp(
        serverUrl: 'https://vault.bitwarden.com',
        email: 'a@b.com',
        masterPasswordHashB64: 'h',
        deviceId: 'dev',
      );
      expect(adapter.urls, [
        'POST https://api.bitwarden.eu/two-factor/send-email-login',
        'POST https://api.bitwarden.com/accounts/resend-new-device-otp',
      ]);
      expect(adapter.requests[0].data, {
        'email': 'a@b.com',
        'masterPasswordHash': 'h',
        'deviceIdentifier': 'dev',
      });
      expect(
        adapter.requests[1].data,
        {'email': 'a@b.com', 'masterPasswordHash': 'h'},
      );
      expect(adapter.requests[1].headers['Device-Identifier'], 'dev');
    });
  });

  group('pending requests (F8, F5, A1, A2)', () {
    test('uses /pending, filters, fingerprints, skips broken items', () async {
      final now = DateTime.now().toUtc();
      adapter.handler = (o) => _json(
            200,
            {
              'data': [
                _item('ok', created: now.subtract(const Duration(minutes: 1))),
                _item('no-key', publicKey: null),
                {'publicKey': _sdkPublicKey}, // no id
                'garbage',
                _item('bad-key',
                    publicKey: 'AAAA',
                    created: now.subtract(const Duration(seconds: 30))),
                _item('approved', approved: true),
                _item('expired',
                    created: now.subtract(const Duration(minutes: 6))),
              ],
              'continuationToken': null,
              'object': 'list',
            },
            headers: {
              'date': [HttpDate.format(DateTime.now())],
            },
          );
      api.configure(_base, _session());
      final list = await api.getPendingRequests();
      expect(adapter.urls.single, 'GET $_base/api/auth-requests/pending');
      expect(
        adapter.requests.single.headers['Authorization'],
        'Bearer at',
      );
      expect(list.map((r) => r.id), ['bad-key', 'ok']);
      expect(
          list.last.fingerprint, 'childless-unfair-prowler-dropbox-designate');
      expect(list.first.fingerprint, isNull); // UI must disable Approve
      final withExpired = await api.getPendingRequests(includeExpired: true);
      expect(withExpired.map((r) => r.id), ['bad-key', 'ok', 'expired']);
    });

    test('404 on /pending → legacy route, remembered per server', () async {
      adapter.handler = (o) => o.path.endsWith('/pending')
          ? _json(404, _vwError('Not found'))
          : _json(200, {'data': []});
      api.configure(_base, _session());
      await api.getPendingRequests();
      await api.getPendingRequests();
      expect(adapter.urls, [
        'GET $_base/api/auth-requests/pending',
        'GET $_base/api/auth-requests',
        'GET $_base/api/auth-requests',
      ]);
    });

    test('old Vaultwarden routes /pending to /{id} → fallback too', () async {
      adapter.handler = (o) => o.path.endsWith('/pending')
          ? _json(400, _vwError("AuthRequest doesn't exist"))
          : _json(200, {'data': []});
      api.configure(_base, _session());
      await api.getPendingRequests();
      expect(adapter.urls.last, 'GET $_base/api/auth-requests');
    });

    test('old official server: /pending hits Get(Guid id) → 400 → fallback',
        () async {
      // bitwarden/server before 2025-06-30: ModelStateValidationFilter →
      // ErrorResponseModel(ModelState).
      adapter.handler = (o) => o.path.endsWith('/pending')
          ? _json(400, {
              'message': 'The model state is invalid.',
              'validationErrors': {
                'id': ["The value 'pending' is not valid."],
              },
              'exceptionMessage': null,
              'exceptionStackTrace': null,
              'innerExceptionMessage': null,
              'object': 'error',
            })
          : _json(200, {'data': []});
      api.configure(_base, _session());
      await api.getPendingRequests();
      await api.getPendingRequests();
      expect(adapter.urls, [
        'GET $_base/api/auth-requests/pending',
        'GET $_base/api/auth-requests',
        'GET $_base/api/auth-requests',
      ]);
    });

    test('other 400s on /pending are real errors (no fallback)', () async {
      adapter.handler = (o) => _json(400, _vwError('Something else'));
      api.configure(_base, _session());
      await expectLater(
        api.getPendingRequests(),
        throwsA(isA<ServerException>()),
      );
      expect(adapter.urls, ['GET $_base/api/auth-requests/pending']);
    });

    test('mTLS: TCP reset instead of the TLS alert (F1 race)', () async {
      adapter.handler =
          (o) => throw const HttpException('Connection reset by peer');
      api.configure(_base, _session());
      await expectLater(
        api.getPendingRequests(),
        throwsA(isA<ClientCertificateRequiredException>()
            .having((e) => e.definitive, 'definitive', isFalse)),
      );
    });

    test('bitwarden.com: api host, answered and superseded dropped', () async {
      final now = DateTime.now().toUtc();
      adapter.handler = (o) => _json(200, {
            'Data': [
              _item('old',
                  device: 'D',
                  created: now.subtract(const Duration(minutes: 2)))
                ..['requestApproved'] = false,
              _item('new',
                  device: 'D',
                  created: now.subtract(const Duration(minutes: 1)))
                ..['requestApproved'] = false,
              _item('denied',
                  approved: false, responseDate: now.toIso8601String()),
              _item('other', device: 'E', created: now),
            ],
          }, headers: {
            'date': [HttpDate.format(DateTime.now())],
          });
      api.configure('https://vault.bitwarden.com',
          _session(serverUrl: 'https://vault.bitwarden.com'));
      final list = await api.getPendingRequests();
      expect(
        adapter.urls.single,
        'GET https://api.bitwarden.com/auth-requests/pending',
      );
      expect(list.map((r) => r.id), ['other', 'new']);
    });

    test('server clock offset from the Date header', () async {
      // Server clock 10 min ahead: a request created "now" on the phone is
      // already 10 minutes old on the server → expired.
      final serverNow = DateTime.now().toUtc().add(const Duration(minutes: 10));
      adapter.handler = (o) => _json(
            200,
            {
              'data': [_item('r', created: DateTime.now().toUtc())],
            },
            headers: {
              'date': [HttpDate.format(serverNow)],
            },
          );
      api.configure(_base, _session());
      expect(await api.getPendingRequests(), isEmpty);
      expect(
        api.serverClockOffset.inMinutes,
        inInclusiveRange(9, 10),
      );
      final all = await api.getPendingRequests(includeExpired: true);
      expect(all.single.isActionable, isFalse);
    });

    test('no Date header → GET /api/now once (A2)', () async {
      final serverNow = DateTime.now().toUtc().add(const Duration(minutes: 3));
      adapter.handler = (o) {
        if (o.path.endsWith('/now')) {
          return _json(200, serverNow.toIso8601String(), date: false);
        }
        return _json(
          200,
          {
            'data': [
              _item('r',
                  created: DateTime.now()
                      .toUtc()
                      .subtract(const Duration(minutes: 1))),
            ],
          },
          date: false,
        );
      };
      api.configure(_base, _session());
      final first = await api.getPendingRequests(includeExpired: true);
      await api.getPendingRequests(includeExpired: true);
      expect(
        adapter.urls.where((u) => u.endsWith('/api/now')),
        hasLength(1),
      );
      expect(first.single.serverClockOffset.inMinutes, inInclusiveRange(2, 3));
      // 1 min old locally + 3 min offset = 4 min old → ~1 min left.
      expect(first.single.remaining().inMinutes, lessThanOrEqualTo(1));
    });

    test('approve/deny payload is unchanged (compatible_ok)', () async {
      adapter.handler = (o) => _json(200, {});
      api.configure(_base, _session());
      await api.respondToAuthRequest(
        requestId: 'req-1',
        approved: true,
        encryptedKey: '4.abc',
        deviceId: 'dev-id',
      );
      await api.respondToAuthRequest(
        requestId: 'req-2',
        approved: false,
        deviceId: 'dev-id',
      );
      expect(adapter.urls, [
        'PUT $_base/api/auth-requests/req-1',
        'PUT $_base/api/auth-requests/req-2',
      ]);
      expect(adapter.requests[0].data, {
        'key': '4.abc',
        'masterPasswordHash': null,
        'deviceIdentifier': 'dev-id',
        'requestApproved': true,
      });
      expect(adapter.requests[1].data, {
        'key': '',
        'masterPasswordHash': null,
        'deviceIdentifier': 'dev-id',
        'requestApproved': false,
      });
    });

    test('typed PUT errors', () async {
      api.configure(_base, _session());
      adapter.handler = (o) => _json(400, {
            'message':
                'This request is no longer valid. Make sure to approve the most recent request.',
          });
      await expectLater(
        api.respondToAuthRequest(requestId: 'r', approved: true, deviceId: 'd'),
        throwsA(isA<AuthRequestSupersededException>()),
      );
      adapter.handler = (o) => _json(
            400,
            _vwError(
                'An authentication request with the same device already exists'),
          );
      await expectLater(
        api.respondToAuthRequest(requestId: 'r', approved: true, deviceId: 'd'),
        throwsA(isA<AuthRequestAlreadyAnsweredException>()),
      );
    });

    test('without configure → StateError', () async {
      await expectLater(api.getPendingRequests(), throwsA(isA<StateError>()));
    });
  });

  group('token refresh (F11)', () {
    ResponseBody refreshOk(RequestOptions o, {String token = 'at2'}) => _json(
          200,
          {
            'access_token': token,
            'refresh_token': 'rt',
            'expires_in': 7200,
            'token_type': 'Bearer',
          },
        );

    test('single-flight pre-emptive refresh for concurrent calls', () async {
      final gate = Completer<void>();
      adapter.handler = (o) async {
        if (o.path.endsWith('/connect/token')) {
          await gate.future;
          return refreshOk(o);
        }
        return _json(200, {'data': []});
      };
      api.configure(_base, _session(expiresIn: const Duration(seconds: 10)));
      final refreshed = <UserSession>[];
      api.onSessionRefreshed.listen(refreshed.add);
      final calls = [
        api.getPendingRequests(),
        api.getPendingRequests(),
        api.getPendingRequests(),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.complete();
      await Future.wait(calls);
      final tokenPosts =
          adapter.requests.where((r) => r.path.endsWith('/connect/token'));
      expect(tokenPosts, hasLength(1));
      expect(tokenPosts.single.data, {
        'grant_type': 'refresh_token',
        'refresh_token': 'rt',
        'client_id': 'mobile',
      });
      final gets = adapter.requests.where((r) => r.method == 'GET');
      expect(gets, hasLength(3));
      for (final g in gets) {
        expect(g.headers['Authorization'], 'Bearer at2');
      }
      await Future<void>.delayed(Duration.zero);
      expect(refreshed.single.accessToken, 'at2');
      expect((await storage.loadSession())!.accessToken, 'at2');
    });

    test('401 → one refresh → one retry', () async {
      adapter.handler = (o) {
        if (o.path.endsWith('/connect/token')) return refreshOk(o);
        final auth = o.headers['Authorization'];
        return auth == 'Bearer at2'
            ? _json(200, {'data': []})
            : _json(401, _vwError('Invalid token'));
      };
      api.configure(_base, _session());
      await api.getPendingRequests();
      expect(adapter.urls, [
        'GET $_base/api/auth-requests/pending',
        'POST $_base/identity/connect/token',
        'GET $_base/api/auth-requests/pending',
      ]);
    });

    test('401 persists after a successful refresh → no loop', () async {
      adapter.handler = (o) => o.path.endsWith('/connect/token')
          ? refreshOk(o)
          : _json(401, _vwError('Invalid token'));
      api.configure(_base, _session());
      await expectLater(
        api.getPendingRequests(),
        throwsA(
            isA<ServerException>().having((e) => e.statusCode, 'status', 401)),
      );
      expect(adapter.requests, hasLength(3));
      expect(api.isSessionEnded, isFalse);

      // The fresh token was refused too: the next call must not refresh
      // (and retry) again — one GET, no POST /connect/token (F11 rate limit).
      await expectLater(
        api.getPendingRequests(),
        throwsA(
            isA<ServerException>().having((e) => e.statusCode, 'status', 401)),
      );
      expect(adapter.urls.skip(3), ['GET $_base/api/auth-requests/pending']);
      expect(
        adapter.requests.where((r) => r.path.endsWith('/connect/token')),
        hasLength(1),
      );
    });

    test('invalid_grant → SessionEndedException, then fail fast', () async {
      adapter.handler = (o) => o.path.endsWith('/connect/token')
          ? _json(400, {'error': 'invalid_grant'})
          : _json(200, {'data': []});
      api.configure(_base, _session(expiresIn: Duration.zero));
      final ended = <SessionEndedException>[];
      api.onSessionEnded.listen(ended.add);
      await expectLater(
        api.getPendingRequests(),
        throwsA(isA<SessionEndedException>().having(
          (e) => e.reason,
          'reason',
          SessionEndReason.refreshTokenRejected,
        )),
      );
      expect(adapter.requests, hasLength(1)); // only the refresh POST
      await expectLater(
        api.getPendingRequests(),
        throwsA(isA<SessionEndedException>()),
      );
      await expectLater(
        api.respondToAuthRequest(
            requestId: 'r', approved: false, deviceId: 'd'),
        throwsA(isA<SessionEndedException>()),
      );
      await expectLater(
        api.getValidAccessToken(),
        throwsA(isA<SessionEndedException>()),
      );
      expect(adapter.requests, hasLength(1)); // no further traffic
      await Future<void>.delayed(Duration.zero);
      expect(ended, hasLength(1));
      expect(api.isSessionEnded, isTrue);

      // Re-configuring the same dead refresh token keeps failing fast …
      api.configure(_base, _session(expiresIn: Duration.zero));
      await expectLater(
        api.getPendingRequests(),
        throwsA(isA<SessionEndedException>()),
      );
      expect(adapter.requests, hasLength(1));
      // … a fresh login (new refresh token) works again.
      api.configure(_base, _session(refreshToken: 'rt-new'));
      await api.getPendingRequests();
      expect(api.isSessionEnded, isFalse);
    });

    test('401 on the API + invalid_grant on refresh → SessionEnded', () async {
      adapter.handler = (o) => o.path.endsWith('/connect/token')
          ? _json(400, {'error': 'invalid_grant'})
          : _json(401, _vwError('Invalid token'));
      api.configure(_base, _session());
      await expectLater(
        api.getPendingRequests(),
        throwsA(isA<SessionEndedException>()),
      );
      expect(adapter.requests, hasLength(2));
    });

    test('refresh rejected (non invalid_grant) + 401 → SessionEnded', () async {
      adapter.handler = (o) => o.path.endsWith('/connect/token')
          ? _json(400, {'error': 'invalid_client'})
          : _json(401, _vwError('Invalid token'));
      api.configure(_base, _session(expiresIn: Duration.zero));
      await expectLater(
        api.getPendingRequests(),
        throwsA(isA<SessionEndedException>().having(
          (e) => e.reason,
          'reason',
          SessionEndReason.unauthorizedAfterRefreshFailure,
        )),
      );
      // one pre-emptive refresh, one GET, no second refresh
      expect(adapter.urls, [
        'POST $_base/identity/connect/token',
        'GET $_base/api/auth-requests/pending',
      ]);
    });

    test('transient refresh failure does not end the session', () async {
      adapter.handler = (o) {
        if (o.path.endsWith('/connect/token')) {
          throw DioException.connectionError(
            requestOptions: o,
            reason: 'offline',
          );
        }
        return _json(401, _vwError('Invalid token'));
      };
      api.configure(_base, _session());
      await expectLater(
          api.getPendingRequests(), throwsA(isA<ServerException>()));
      expect(api.isSessionEnded, isFalse);
    });

    test('getValidAccessToken', () async {
      expect(await api.getValidAccessToken(), isNull);
      adapter.handler = (o) => refreshOk(o, token: 'fresh');
      api.configure(_base, _session());
      expect(await api.getValidAccessToken(), 'at');
      expect(adapter.requests, isEmpty);
      expect(await api.getValidAccessToken(forceRefresh: true), 'fresh');
      adapter.handler = (o) => _json(400, {'error': 'invalid_client'});
      await expectLater(
        api.getValidAccessToken(forceRefresh: true),
        throwsA(isA<SessionEndedException>()),
      );
    });

    test('reset() forgets the session', () async {
      api.configure(_base, _session());
      api.reset();
      expect(api.session, isNull);
      expect(api.environment, isNull);
      await expectLater(api.getPendingRequests(), throwsA(isA<StateError>()));
    });
  });

  test('fixture key is a valid request key', () async {
    adapter.handler = (o) => _json(200, {
          'data': [_item('x', publicKey: fixtureRsaSpkiB64)],
        });
    api.configure(_base, _session());
    final list = await api.getPendingRequests();
    expect(list.single.fingerprint, isNotNull);
  });
}
