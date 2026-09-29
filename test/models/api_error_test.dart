import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/models/api_error.dart';

/// Vaultwarden's standard error body (src/error.rs): the text is in
/// `message` / `errorModel.message`, `error` and `error_description` are "".
Map<String, dynamic> _vw(String message) => {
      'message': message,
      'validationErrors': {
        '': [message],
      },
      'errorModel': {'message': message, 'object': 'error'},
      'error': '',
      'error_description': '',
      'exceptionMessage': null,
      'exceptionStackTrace': null,
      'innerExceptionMessage': null,
      'object': 'error',
    };

/// Bitwarden identity error: `error` + `error_description` + PascalCase
/// `ErrorModel.Message`.
Map<String, dynamic> _bw(String error, String description, String message) => {
      'error': error,
      'error_description': description,
      'ErrorModel': {'Message': message, 'Object': 'error'},
    };

void main() {
  group('extractServerMessage (F9)', () {
    test('Vaultwarden: skips the empty error/error_description', () {
      expect(
        extractServerMessage(
            _vw('Username or password is incorrect. Try again')),
        'Username or password is incorrect. Try again',
      );
    });

    test('Bitwarden: ErrorModel.Message then error_description then error', () {
      expect(
        extractServerMessage(_bw('invalid_grant', 'desc', 'Model message')),
        'Model message',
      );
      expect(
        extractServerMessage(
            {'error': 'invalid_grant', 'error_description': 'd'}),
        'd',
      );
      expect(extractServerMessage({'error': 'invalid_grant'}), 'invalid_grant');
      expect(extractServerMessage({'Message': 'Pascal'}), 'Pascal');
    });

    test('JSON string bodies are decoded; HTML is ignored', () {
      expect(extractServerMessage('{"message":"hi"}'), 'hi');
      expect(extractServerMessage('<html>502</html>'), isNull);
      expect(extractServerMessage(''), isNull);
      expect(extractServerMessage(null), isNull);
    });
  });

  group('ApiException.fromResponse', () {
    test('wrong password (VW and BW) → InvalidCredentialsException', () {
      final vw = ApiException.fromResponse(
        400,
        _vw('Username or password is incorrect. Try again'),
      );
      expect(vw, isA<InvalidCredentialsException>());
      expect(vw.serverMessage, 'Username or password is incorrect. Try again');
      final bw = ApiException.fromResponse(
        400,
        _bw(
          'invalid_grant',
          'Username or password is incorrect. Try again.',
          'Username or password is incorrect. Try again.',
        ),
      );
      expect(bw, isA<InvalidCredentialsException>());
    });

    test('2FA required (VW json_err_twofactor) with provider data', () {
      final e = ApiException.fromResponse(400, {
        'error': 'invalid_grant',
        'error_description': 'Two factor required.',
        'TwoFactorProviders': ['0', '1'],
        'TwoFactorProviders2': {
          '0': null,
          '1': {'Email': 'u***@example.com'},
        },
        'MasterPasswordPolicy': {'Object': 'masterPasswordPolicy'},
      });
      expect(e, isA<TwoFactorRequiredException>());
      final t = e as TwoFactorRequiredException;
      expect(t.availableProviders, [0, 1]);
      expect(t.hasTotp, isTrue);
      expect(t.hasEmail, isTrue);
      expect(t.obscuredEmail, 'u***@example.com');
    });

    test('2FA required with only TwoFactorProviders2 (BW) or description', () {
      final e = ApiException.fromResponse(400, {
        'error': 'invalid_grant',
        'error_description': 'Two factor required.',
        'TwoFactorProviders2': {
          '3': {'Nfc': true},
          '8': null
        },
      }) as TwoFactorRequiredException;
      expect(e.availableProviders, [3, 8]);
      final bare = ApiException.fromResponse(
        400,
        {'error': 'invalid_grant', 'error_description': 'Two factor required.'},
      ) as TwoFactorRequiredException;
      expect(bare.availableProviders, [0]);
    });

    test('remember token rejected (VW) is again "2FA required"', () {
      final e = ApiException.fromResponse(400, {
        'error': 'invalid_grant',
        'error_description': 'Two factor required.',
        'TwoFactorProviders': ['0'],
        'TwoFactorProviders2': {'0': null},
      });
      expect(e, isA<TwoFactorRequiredException>());
    });

    test('wrong 2FA codes → InvalidTwoFactorCodeException', () {
      for (final body in [
        _vw('Invalid TOTP code! Server time: 2026-09-26 10:00:00 UTC IP: 192.0.2.1'),
        _vw('Token is invalid! IP: 192.0.2.1'),
        _vw('Token has expired'),
        _vw('Invalid Yubikey OTP length'),
        _vw('Recovery code is incorrect. Try again.'),
        _bw('invalid_grant', 'Two-step token is invalid. Try again.',
            'Two-step token is invalid. Try again.'),
      ]) {
        expect(
          ApiException.fromResponse(400, body),
          isA<InvalidTwoFactorCodeException>(),
          reason: '$body',
        );
      }
    });

    test('new device verification (F6) and invalid OTP (A3)', () {
      expect(
        ApiException.fromResponse(
          400,
          _bw('device_error', 'New device verification required',
              'new device verification required'),
        ),
        isA<NewDeviceVerificationRequiredException>(),
      );
      expect(
        ApiException.fromResponse(
          400,
          _bw('device_error', 'Invalid New Device OTP',
              'invalid new device otp'),
        ),
        isA<InvalidNewDeviceOtpException>(),
      );
    });

    test('client version rejected (F2 regression guard)', () {
      expect(
        ApiException.fromResponse(400, {
          'error': 'version_header_missing',
          'error_description': 'No client version header found',
        }),
        isA<ClientVersionRejectedException>(),
      );
      expect(
        ApiException.fromResponse(400, {'error': 'invalid_client_version'}),
        isA<ClientVersionRejectedException>(),
      );
    });

    test('429 → RateLimitedException with Retry-After', () {
      final e = ApiException.fromResponse(
        429,
        _vw('Too many login requests'),
        headers: {
          'retry-after': ['30'],
        },
      ) as RateLimitedException;
      expect(e.retryAfter, const Duration(seconds: 30));
      expect(e.serverMessage, 'Too many login requests');
    });

    test('auth request errors', () {
      expect(
        ApiException.fromResponse(400, {
          'message':
              'This request is no longer valid. Make sure to approve the most recent request.',
        }),
        isA<AuthRequestSupersededException>(),
      );
      expect(
        ApiException.fromResponse(
          400,
          _vw('An authentication request with the same device already exists'),
        ),
        isA<AuthRequestAlreadyAnsweredException>(),
      );
      expect(
        ApiException.fromResponse(400, _vw("AuthRequest doesn't exist")),
        isA<AuthRequestNotFoundException>(),
      );
    });

    test('anything else → ServerException with the server text', () {
      final e =
          ApiException.fromResponse(400, _vw('This user has been disabled'));
      expect(e, isA<ServerException>());
      expect(e.serverMessage, 'This user has been disabled');
      expect(e.statusCode, 400);
      expect(e.code, ApiErrorCode.server);
      final empty = ApiException.fromResponse(502, '<html>Bad gateway</html>');
      expect(empty, isA<ServerException>());
      expect(empty.serverMessage, isNull);
    });
  });

  group('ClientCertificateRequiredException.classify (F1)', () {
    test('TLS alerts about the client certificate', () {
      for (final msg in [
        'TLSV1_ALERT_CERTIFICATE_REQUIRED(tls_record.cc:486)',
        'SSLV3_ALERT_BAD_CERTIFICATE',
        'TLSV1_ALERT_UNKNOWN_CA',
        'SSLV3_ALERT_HANDSHAKE_FAILURE',
        'SSLV3_ALERT_CERTIFICATE_EXPIRED',
      ]) {
        final e = ClientCertificateRequiredException.classify(
          HandshakeException('Handshake error in client', OSError(msg, 1)),
          certificatePresented: true,
        );
        expect(e, isNotNull, reason: msg);
        expect(e!.definitive, isTrue);
        expect(e.certificatePresented, isTrue);
      }
    });

    test('connection reset during the handshake → heuristic', () {
      final e = ClientCertificateRequiredException.classify(
        const HandshakeException(
          'Connection terminated during handshake',
        ),
      );
      expect(e, isNotNull);
      expect(e!.definitive, isFalse);
    });

    test('TCP reset instead of the TLS alert → heuristic, only over TLS', () {
      const error = HttpException('Connection reset by peer');
      final e = ClientCertificateRequiredException.classify(
        error,
        certificatePresented: true,
        secure: true,
      );
      expect(e, isNotNull);
      expect(e!.definitive, isFalse);
      expect(e.certificatePresented, isTrue);
      // Plain HTTP cannot be an mTLS problem.
      expect(ClientCertificateRequiredException.classify(error), isNull);
      // A write on a stale keep-alive connection is a network error.
      expect(
        ClientCertificateRequiredException.classify(
          const SocketException(
            'Write failed',
            osError: OSError('Connection reset by peer', 54),
          ),
          secure: true,
        ),
        isNull,
      );
    });

    test('server certificate problems are NOT client-certificate problems', () {
      expect(
        ClientCertificateRequiredException.classify(
          const HandshakeException(
            'Handshake error in client',
            OSError('CERTIFICATE_VERIFY_FAILED: unable to get local issuer', 1),
          ),
        ),
        isNull,
      );
      expect(
        ClientCertificateRequiredException.classify(
          const SocketException('Connection refused'),
        ),
        isNull,
      );
    });
  });
}
