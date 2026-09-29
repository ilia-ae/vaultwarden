import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/models/server_environment.dart';
import 'package:vault_approver/models/user_session.dart';
import 'package:vault_approver/services/client_cert_service.dart';
import 'package:vault_approver/services/notification_service.dart';
import 'package:vault_approver/services/secure_storage_service.dart';
import 'package:vault_approver/services/vault_api.dart';

import 'mtls_fixtures.dart';

Uint8List _p12(String b64) => base64Decode(b64);

/// A 30-day 'localhost' certificate signed by the test CA, minted with the
/// openssl CLI (Apple's trust evaluation rejects server certificates valid
/// for more than 825 days, so a long-lived fixture cannot be used). Falls back
/// to [fixtureServerPem] (valid until 2028) when openssl is unavailable.
Future<String?> _serverCertificatePem() async {
  Directory? dir;
  try {
    dir = await Directory.systemTemp.createTemp('va_mtls_');
    final p = dir.path;
    await File('$p/ca.pem').writeAsString(fixtureCaPem);
    await File('$p/ca.key').writeAsString(fixtureCaKeyPem);
    await File('$p/server.key').writeAsString(fixtureServerKeyPem);
    await File('$p/ext').writeAsString(
      'subjectAltName=DNS:localhost,IP:127.0.0.1\n'
      'extendedKeyUsage=serverAuth\n'
      'keyUsage=critical,digitalSignature\n',
    );
    final csr = await Process.run('openssl', [
      'req', '-new', '-key', '$p/server.key', '-subj', '/CN=localhost', //
      '-out', '$p/server.csr',
    ]);
    if (csr.exitCode != 0) return null;
    final crt = await Process.run('openssl', [
      'x509', '-req', '-in', '$p/server.csr', '-CA', '$p/ca.pem', //
      '-CAkey', '$p/ca.key', '-set_serial',
      '${DateTime.now().millisecondsSinceEpoch}',
      '-days', '30', '-sha256', '-extfile', '$p/ext', '-out', '$p/server.pem',
    ]);
    if (crt.exitCode != 0) return null;
    return await File('$p/server.pem').readAsString();
  } catch (_) {
    return null;
  } finally {
    try {
      await dir?.delete(recursive: true);
    } catch (_) {}
  }
}

/// A local HTTPS server that REQUIRES a client certificate from the test CA
/// (like Caddy `client_auth require_and_verify` on the stand).
Future<HttpServer> _startMtlsServer(String serverPem) async {
  final ctx = SecurityContext()
    ..useCertificateChainBytes(utf8.encode(serverPem))
    ..usePrivateKeyBytes(utf8.encode(fixtureServerKeyPem))
    ..setTrustedCertificatesBytes(utf8.encode(fixtureCaPem))
    ..setClientAuthoritiesBytes(utf8.encode(fixtureCaPem));
  final socket = await SecureServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
    ctx,
    requireClientCertificate: true,
  );
  final server = HttpServer.listenOn(_SecureServerSocketAdapter(socket));
  server.listen(
    (request) async {
      if (request.uri.path == '/identity/accounts/prelogin') {
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'kdf': 0,
            'kdfIterations': 600000,
            'subject': request.certificate?.subject,
          }));
        await request.response.close();
        return;
      }
      if (request.uri.path == '/notifications/hub') {
        final ws = await WebSocketTransformer.upgrade(request);
        ws.listen((message) {
          if (message is String && message.contains('messagepack')) {
            ws.add(Uint8List.fromList([0x7b, 0x7d, 0x1e]));
          }
        });
        return;
      }
      request.response.statusCode = 404;
      await request.response.close();
    },
    onError: (Object _) {},
  );
  return server;
}

/// Lets [HttpServer.listenOn] serve a [SecureServerSocket] bound with
/// `requireClientCertificate: true` (HttpServer.bindSecure can only request).
class _SecureServerSocketAdapter extends Stream<Socket>
    implements ServerSocket {
  _SecureServerSocketAdapter(this._inner);

  final SecureServerSocket _inner;

  @override
  StreamSubscription<Socket> listen(
    void Function(Socket event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _inner.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  int get port => _inner.port;

  @override
  InternetAddress get address => _inner.address;

  @override
  Future<ServerSocket> close() async {
    await _inner.close();
    return this;
  }
}

void main() {
  late ClientCertService certs;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    certs = ClientCertService(extraTrustedCaPem: fixtureCaPem);
  });

  group('inspect (F1, A14)', () {
    final variants = {
      'compatibility2022 (3DES, SHA-1 MAC)': fixtureP12Compat2022,
      'OpenSSL 3 default (PBES2 AES-256, SHA-256 MAC)': fixtureP12Modern,
      'OpenSSL -legacy (RC2-40)': fixtureP12Legacy,
      'unencrypted certificates': fixtureP12Nocertenc,
    };
    for (final v in variants.entries) {
      test('accepts ${v.key}; leaf = chain[0], not the CA', () {
        final info = certs.inspect(_p12(v.value), fixtureP12Password);
        expect(info.commonName, 'test-device');
        expect(info.subject, 'CN=test-device, O=ilia.ae');
        expect(info.issuer, 'CN=VA Test mTLS CA, O=VA Test');
        expect(info.certificateCount, 2);
        expect(info.notAfter!.year, 2046);
        expect(info.notAfter!.isUtc, isTrue);
        expect(info.notBefore!.isBefore(info.notAfter!), isTrue);
      });
    }

    test('inspectAsync (background isolate) gives the same result', () async {
      final info = await certs.inspectAsync(
          _p12(fixtureP12Compat2022), fixtureP12Password);
      expect(info.subject, 'CN=test-device, O=ilia.ae');
      await expectLater(
        certs.inspectAsync(_p12(fixtureP12Compat2022), 'bad'),
        throwsA(isA<ClientCertBadPasswordException>()),
      );
    });

    test('wrong password → ClientCertBadPasswordException', () {
      for (final b64 in [
        fixtureP12Compat2022,
        fixtureP12Modern,
        fixtureP12Legacy
      ]) {
        expect(
          () => certs.inspect(_p12(b64), 'wrong'),
          throwsA(isA<ClientCertBadPasswordException>()),
        );
      }
    });

    test('no private key / garbage → ClientCertUnsupportedFormatException', () {
      expect(
        () => certs.inspect(_p12(fixtureP12Nokey), fixtureP12Password),
        throwsA(isA<ClientCertUnsupportedFormatException>()),
      );
      expect(
        () => certs.inspect(Uint8List.fromList(utf8.encode('hello')), 'x'),
        throwsA(isA<ClientCertUnsupportedFormatException>()),
      );
      expect(
        () => certs.inspect(
          Uint8List.fromList(utf8.encode(fixtureClientPem)),
          'x',
        ),
        throwsA(isA<ClientCertException>()),
      );
    });

    test('isExpiringSoon (< 30 days) and isExpired', () {
      final info = certs.inspect(_p12(fixtureP12Modern), fixtureP12Password);
      final end = info.notAfter!;
      expect(info.isExpiringSoon(now: end.subtract(const Duration(days: 31))),
          isFalse);
      expect(info.isExpiringSoon(now: end.subtract(const Duration(days: 29))),
          isTrue);
      expect(
          info.isExpired(now: end.subtract(const Duration(days: 1))), isFalse);
      expect(info.isExpired(now: end.add(const Duration(seconds: 1))), isTrue);
      expect(
          info.isExpiringSoon(now: end.add(const Duration(days: 1))), isTrue);
      expect(
        info.timeLeft(now: end.subtract(const Duration(days: 2))),
        const Duration(days: 2),
      );
    });
  });

  group('storage', () {
    test('import / load / remove per origin, emits changes', () async {
      final changes = <String>[];
      final sub = certs.changes.listen(changes.add);
      final rev0 = certs.revision;

      final info = await certs.importCertificate(
        serverUrl: 'https://Vault-Test.example.com:2053/',
        pkcs12: _p12(fixtureP12Compat2022),
        password: fixtureP12Password,
      );
      expect(info.commonName, 'test-device');
      expect(certs.revision, greaterThan(rev0));

      final stored =
          await certs.load('https://vault-test.example.com:2053/api/x');
      expect(stored, isNotNull);
      expect(stored!.origin, 'https://vault-test.example.com:2053');
      expect(stored.password, fixtureP12Password);
      expect(stored.toString(), isNot(contains(fixtureP12Password)));
      expect((await certs.info('https://vault-test.example.com:2053'))!.subject,
          'CN=test-device, O=ilia.ae');
      expect(await certs.hasCertificate('https://vault-test.example.com'),
          isFalse); // other port = other origin

      // Persisted in the secure store under the documented key.
      final raw = await const FlutterSecureStorage().readAll();
      expect(raw.keys,
          contains('client_cert|https://vault-test.example.com:2053'));

      // A fresh instance reads it back.
      final other = ClientCertService();
      expect(await other.hasCertificate('https://vault-test.example.com:2053'),
          isTrue);

      await certs.remove('https://vault-test.example.com:2053');
      expect(await certs.load('https://vault-test.example.com:2053'), isNull);
      await Future<void>.delayed(Duration.zero);
      expect(changes, [
        'https://vault-test.example.com:2053',
        'https://vault-test.example.com:2053',
      ]);
      await sub.cancel();
    });

    test('import with a wrong password stores nothing', () async {
      await expectLater(
        certs.importCertificate(
          serverUrl: 'https://x.example.com',
          pkcs12: _p12(fixtureP12Modern),
          password: 'nope',
        ),
        throwsA(isA<ClientCertBadPasswordException>()),
      );
      expect(await certs.load('https://x.example.com'), isNull);
    });

    test('certificates survive clearSessionData (A13)', () async {
      await certs.importCertificate(
        serverUrl: 'https://x.example.com',
        pkcs12: _p12(fixtureP12Modern),
        password: fixtureP12Password,
      );
      await SecureStorageService().clearSessionData();
      expect(await ClientCertService().hasCertificate('https://x.example.com'),
          isTrue);
    });

    test('invalid extra CA is rejected', () async {
      await expectLater(
        certs.setTrustedCaPem('https://x.example.com', 'not a pem'),
        throwsA(isA<ClientCertInvalidCaException>()),
      );
      await certs.setTrustedCaPem('https://x.example.com', fixtureCaPem);
      expect(await certs.trustedCaPem('https://x.example.com'), fixtureCaPem);
      await certs.setTrustedCaPem('https://x.example.com', null);
      expect(await certs.trustedCaPem('https://x.example.com'), isNull);
    });
  });

  group('mTLS transport against a server that requires a certificate', () {
    late HttpServer server;
    late String base;
    String? serverPem;

    setUpAll(() async {
      serverPem = await _serverCertificatePem() ?? fixtureServerPem;
    });

    setUp(() async {
      server = await _startMtlsServer(serverPem!);
      base = 'https://localhost:${server.port}';
    });

    tearDown(() => server.close(force: true));

    test('REST: no cert → ClientCertificateRequiredException; import → works',
        () async {
      final api = VaultApiService(SecureStorageService(), clientCerts: certs);
      await expectLater(
        api.prelogin(base, 'a@b.com'),
        throwsA(isA<ClientCertificateRequiredException>().having(
          (e) => e.certificatePresented,
          'certificatePresented',
          isFalse,
        )),
      );

      await certs.importCertificate(
        serverUrl: base,
        pkcs12: _p12(fixtureP12Compat2022),
        password: fixtureP12Password,
      );
      final kdf = await api.prelogin(base, 'a@b.com');
      expect(kdf.iterations, 600000);

      // Removing the certificate rebuilds the client again.
      await certs.remove(base);
      await expectLater(
        api.prelogin(base, 'a@b.com'),
        throwsA(isA<ClientCertificateRequiredException>()),
      );
      api.dispose();
    });

    test('hub (wss) uses the same client certificate', () async {
      await certs.importCertificate(
        serverUrl: base,
        pkcs12: _p12(fixtureP12Modern),
        password: fixtureP12Password,
      );
      final hub = NotificationService(clientCerts: certs);
      final connected = hub.states
          .firstWhere((s) => s == HubConnectionState.connected)
          .timeout(const Duration(seconds: 10));
      await hub.connectEnvironment(
        ServerEnvironment.selfHosted(base),
        tokenProvider: ({bool forceRefresh = false}) async => 'token',
      );
      await connected;
      expect(hub.isConnected, isTrue);
      hub.dispose();
    });
  });

  group('a client certificate never leaves its origin', () {
    String? serverPem;

    setUpAll(() async {
      serverPem = await _serverCertificatePem() ?? fixtureServerPem;
    });

    test('concurrent requests to two origins: only the mTLS one presents it',
        () async {
      final mtls = await _startMtlsServer(serverPem!);
      // Origin B asks for (does not require) a client certificate and
      // records what it was given.
      final seen = <String?>[];
      final other = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        SecurityContext()
          ..useCertificateChainBytes(utf8.encode(serverPem!))
          ..usePrivateKeyBytes(utf8.encode(fixtureServerKeyPem))
          ..setTrustedCertificatesBytes(utf8.encode(fixtureCaPem))
          ..setClientAuthoritiesBytes(utf8.encode(fixtureCaPem)),
        requestClientCertificate: true,
      );
      other.listen((request) async {
        seen.add(request.certificate?.subject);
        request.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({'kdf': 0, 'kdfIterations': 600000}));
        await request.response.close();
      });
      final a = 'https://localhost:${mtls.port}';
      final b = 'https://localhost:${other.port}';
      await certs.importCertificate(
        serverUrl: a,
        pkcs12: _p12(fixtureP12Compat2022),
        password: fixtureP12Password,
      );
      final api = VaultApiService(SecureStorageService(), clientCerts: certs);
      try {
        final results = await Future.wait([
          for (var i = 0; i < 5; i++) ...[
            api.prelogin(a, 'a@b.com'),
            api.prelogin(b, 'a@b.com'),
          ],
        ]);
        expect(results, hasLength(10));
        expect(seen, hasLength(5));
        expect(seen, everyElement(isNull));
      } finally {
        api.dispose();
        await mtls.close(force: true);
        await other.close(force: true);
      }
    });

    test('redirects are not followed', () async {
      var targetHits = 0;
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      target.listen((request) async {
        targetHits++;
        request.response.write('{}');
        await request.response.close();
      });
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      origin.listen((request) async {
        request.response
          ..statusCode = HttpStatus.found
          ..headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.1:${target.port}/api/now',
          );
        await request.response.close();
      });
      final base = 'http://127.0.0.1:${origin.port}';
      final api = VaultApiService(SecureStorageService(), clientCerts: certs);
      try {
        api.configure(
          base,
          UserSession(
            email: 'a@b.com',
            serverUrl: base,
            accessToken: 'at',
            refreshToken: 'rt',
            accessTokenExpiry: DateTime.now().add(const Duration(hours: 1)),
          ),
        );
        await expectLater(
          api.getServerTime(),
          throwsA(isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', HttpStatus.found)),
        );
        expect(targetHits, 0);
      } finally {
        api.dispose();
        await origin.close(force: true);
        await target.close(force: true);
      }
    });
  });
}
