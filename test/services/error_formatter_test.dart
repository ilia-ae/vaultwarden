import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/models/api_error.dart';
import 'package:vault_approver/providers/auth_requests_provider.dart';
import 'package:vault_approver/services/auth_exception.dart';
import 'package:vault_approver/services/client_cert_service.dart';
import 'package:vault_approver/utils/error_formatter.dart';

void main() {
  final l = lookupAppLocalizations(const Locale('en'));

  group('formatError (F9)', () {
    test('typed errors map to localized strings', () {
      expect(
        formatError(const InvalidCredentialsException(statusCode: 400), l),
        l.errorInvalidCredentials,
      );
      expect(
        formatError(const InvalidTwoFactorCodeException(), l),
        l.errorInvalidTwoFactorCode,
      );
      expect(
          formatError(const RateLimitedException(), l), l.errorTooManyAttempts);
      expect(
        formatError(
          const RateLimitedException(retryAfter: Duration(seconds: 42)),
          l,
        ),
        l.errorTooManyAttemptsWait(42),
      );
      expect(
        formatError(
          const SessionEndedException(
              reason: SessionEndReason.refreshTokenRejected),
          l,
        ),
        l.sessionEndedOnServer,
      );
      expect(
        formatError(const MissingUserKeyException(), l),
        l.errorMissingUserKey,
      );
      expect(formatError(const KdfTooWeakException('x'), l), l.errorKdfTooWeak);
      expect(
        formatError(const UnsupportedKdfException(9), l),
        l.errorUnsupportedKdf,
      );
      expect(
        formatError(const ClientVersionRejectedException(), l),
        l.errorClientVersionRejected,
      );
      expect(
        formatError(const NewDeviceVerificationRequiredException(), l),
        l.errorNewDeviceVerificationRequired,
      );
      expect(
        formatError(const InvalidNewDeviceOtpException(), l),
        l.errorInvalidNewDeviceOtp,
      );
    });

    test('auth request answers (F8)', () {
      expect(
        formatError(const AuthRequestSupersededException(statusCode: 400), l),
        l.errorAuthRequestSuperseded,
      );
      expect(
        formatError(const AuthRequestAlreadyAnsweredException(), l),
        l.errorAuthRequestAlreadyAnswered,
      );
      expect(
        formatError(const AuthRequestNotFoundException(), l),
        l.errorAuthRequestNotFound,
      );
    });

    test('client certificate required / rejected (F1)', () {
      expect(
        formatError(const ClientCertificateRequiredException(), l),
        l.errorClientCertRequired,
      );
      expect(
        formatError(
          const ClientCertificateRequiredException(certificatePresented: true),
          l,
        ),
        l.errorClientCertRejected,
      );
      expect(
        formatError(
          const ClientCertificateRequiredException(definitive: false),
          l,
        ),
        l.errorClientCertMaybeRequired,
      );
      final options = RequestOptions(path: '/x');
      expect(
        formatError(
          DioException(
            requestOptions: options,
            error: const ClientCertificateRequiredException(),
          ),
          l,
        ),
        l.errorClientCertRequired,
      );
    });

    test('local refusals of the request provider', () {
      expect(
        formatError(const AuthRequestExpiredException(), l),
        l.errorRequestExpired,
      );
      expect(
        formatError(const FingerprintUnavailableException(), l),
        l.errorFingerprintUnavailable,
      );
    });

    test("Vaultwarden's own message is shown, not 'Invalid request'", () {
      final e = ApiException.fromResponse(400, {
        'message': 'This user has been disabled',
        'errorModel': {'message': 'This user has been disabled'},
        'error': '',
        'error_description': '',
      });
      expect(formatError(e, l), 'This user has been disabled');
    });

    test('technical or missing messages fall back to the status text', () {
      expect(
        formatError(const ServerException(statusCode: 404), l),
        l.errorEndpointNotFound,
      );
      expect(
        formatError(
          const ServerException(
            statusCode: 500,
            serverMessage: 'NullReferenceException at line 3',
          ),
          l,
        ),
        l.errorServerRetry(500),
      );
    });

    test('raw DioExceptions with a response are parsed too', () {
      final options = RequestOptions(path: '/x');
      final e = DioException(
        requestOptions: options,
        response: Response(
          requestOptions: options,
          statusCode: 400,
          data: {
            'message': 'Username or password is incorrect. Try again',
            'error': '',
            'error_description': '',
          },
        ),
        type: DioExceptionType.badResponse,
      );
      expect(formatError(e, l), l.errorInvalidCredentials);
    });

    test('client certificate import errors', () {
      expect(
        formatError(const ClientCertBadPasswordException(), l),
        l.errorClientCertBadPassword,
      );
      expect(
        formatError(const ClientCertUnsupportedFormatException('x'), l),
        l.errorClientCertUnsupported,
      );
      expect(
        formatError(const ClientCertInvalidCaException(), l),
        l.errorClientCertInvalidCa,
      );
    });

    test('every locale has a distinct text for every error code', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final loc = lookupAppLocalizations(locale);
        expect(loc.errorClientCertRequired, isNotEmpty);
        expect(loc.errorAuthRequestSuperseded, isNotEmpty);
        if (locale.languageCode != 'en') {
          expect(loc.errorClientCertRequired, isNot(l.errorClientCertRequired),
              reason: '$locale');
          expect(loc.errorAuthRequestSuperseded,
              isNot(l.errorAuthRequestSuperseded),
              reason: '$locale');
        }
      }
    });
  });

  group('classification helpers', () {
    final options = RequestOptions(path: '/x');

    test('isAuthError / isSessionEndedError', () {
      const ended =
          SessionEndedException(reason: SessionEndReason.refreshTokenRejected);
      expect(isAuthError(ended), isTrue);
      expect(isSessionEndedError(ended), isTrue);
      expect(
        isSessionEndedError(
            DioException(requestOptions: options, error: ended)),
        isTrue,
      );
      expect(isAuthError(const ServerException(statusCode: 401)), isTrue);
      expect(isAuthError(const ServerException(statusCode: 400)), isFalse);
    });

    test('isNetworkError', () {
      expect(isNetworkError(const ServerException(statusCode: 500)), isFalse);
      expect(
          isNetworkError(const ClientCertificateRequiredException()), isFalse);
      expect(
        isNetworkError(DioException.connectionError(
          requestOptions: options,
          reason: 'x',
          error: const SocketException('Connection refused'),
        )),
        isTrue,
      );
      expect(
        isNetworkError(DioException(
          requestOptions: options,
          error: const HandshakeException(
            'Handshake error in client',
            OSError('TLSV1_ALERT_CERTIFICATE_REQUIRED', 1),
          ),
        )),
        isFalse,
      );
      expect(
        isClientCertificateError(const ClientCertificateRequiredException()),
        isTrue,
      );
    });
  });

  group('cloud-sync sign-in errors are localised (R9)', () {
    final ru = lookupAppLocalizations(const Locale('ru'));

    test('cancel is silent', () {
      expect(
        describeCloudSyncError(
            AuthException(AuthFailure.cancelled, provider: 'Google'), ru),
        isNull,
      );
    });

    test('every failure maps to a translated text, never English', () {
      final cases = {
        AuthException(AuthFailure.notConfigured, provider: 'Google'):
            ru.cloudSyncErrorNotConfigured,
        AuthException(AuthFailure.unsupported, provider: 'Google'):
            ru.cloudSyncErrorUnsupported('Google'),
        AuthException(AuthFailure.missingToken, provider: 'Google'):
            ru.cloudSyncErrorNoToken('Google'),
        AuthException(AuthFailure.emailInUse, provider: 'Apple'):
            ru.cloudSyncErrorEmailInUse('Apple'),
        AuthException(AuthFailure.failed,
                provider: 'Apple', detail: 'invalid-credential'):
            ru.cloudSyncErrorFailed('Apple', 'invalid-credential'),
        TimeoutException('x'): ru.cloudSyncErrorTimeout,
        StateError('boom'): ru.cloudSyncErrorGeneric,
      };
      cases.forEach((error, expected) {
        final text = describeCloudSyncError(error, ru)!;
        expect(text, expected, reason: '$error');
        expect(text, isNot(contains('sign-in')), reason: '$error');
        expect(text, isNot(contains('cancelled')), reason: '$error');
      });
    });
  });

  group('Arabic counts use plural forms', () {
    final ar = lookupAppLocalizations(const Locale('ar'));

    test('days until a certificate expires', () {
      expect(ar.clientCertExpiresSoon(1, 'd'), contains('يوم واحد'));
      expect(ar.clientCertExpiresSoon(2, 'd'), contains('يومين'));
      expect(ar.clientCertExpiresSoon(5, 'd'), contains('5 أيام'));
      expect(ar.clientCertExpiresSoon(15, 'd'), contains('15 يومًا'));
    });

    test('seconds to wait after a 429', () {
      expect(ar.errorTooManyAttemptsWait(1), contains('ثانية واحدة'));
      expect(ar.errorTooManyAttemptsWait(2), contains('ثانيتين'));
      expect(ar.errorTooManyAttemptsWait(5), contains('5 ثوانٍ'));
      expect(ar.errorTooManyAttemptsWait(30), contains('30 ثانية'));
    });
  });
}
