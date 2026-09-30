import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../l10n/app_localizations.dart';
import '../models/api_error.dart';
import '../services/auth_exception.dart';
import '../services/client_cert_service.dart';
import '../services/secure_storage_service.dart';

/// Formats errors into user-friendly localized messages.
///
/// Handles the typed server errors ([ApiException] — the single place to
/// map an [ApiErrorCode] to text), client-certificate import errors,
/// DioException (network/HTTP errors), crypto errors and common runtime
/// exceptions. Unrecognised server errors show the server's own message
/// (first non-empty of message / errorModel.message / error_description /
/// error, F9) unless it looks technical.
String formatError(Object e, AppLocalizations l) {
  if (e is ApiException) {
    return _formatApiError(e, l);
  }
  if (e is ClientCertException) {
    return _formatClientCertError(e, l);
  }
  if (e is DioException) {
    return _formatDioError(e, l);
  }
  if (e is SocketException) {
    return l.errorCannotConnect;
  }
  if (e is SecureStorageReadException) {
    return l.storageErrorMessage;
  }
  final msg = e.toString();
  // Local refusals of the request provider (matched by name: the provider
  // layer depends on this file, not the other way round).
  if (msg == 'AuthRequestExpiredException') return l.errorRequestExpired;
  if (msg == 'FingerprintUnavailableException') {
    return l.errorFingerprintUnavailable;
  }
  if (msg.contains('MAC verification')) return l.errorInvalidMasterPassword;
  if (msg.contains('FormatException')) return l.errorInvalidServerResponse;
  if (msg.contains('RangeError') || msg.contains("type 'Null'")) {
    return l.errorUnexpectedFormat;
  }
  if (msg.contains('Biometric authentication failed')) {
    return l.errorBiometricFailed;
  }
  if (msg.contains('Setup not completed')) {
    return l.errorSessionExpired;
  }
  if (msg.contains('UserCancelled') || msg.contains('PasscodeNotSet')) {
    return l.errorBiometricFailed;
  }
  return msg.replaceAll('Exception: ', '');
}

/// Maps a typed server error to text: every [ApiErrorCode] has its own
/// localized string; unrecognised server errors show the server's message.
String _formatApiError(ApiException e, AppLocalizations l) {
  return switch (e) {
    TwoFactorRequiredException() => l.twoFactorPrompt,
    InvalidTwoFactorCodeException() => l.errorInvalidTwoFactorCode,
    InvalidCredentialsException() => l.errorInvalidCredentials,
    RateLimitedException(:final retryAfter) =>
      retryAfter != null && retryAfter > Duration.zero
          ? l.errorTooManyAttemptsWait(
              (retryAfter.inMilliseconds / 1000).ceil(),
            )
          : l.errorTooManyAttempts,
    SessionEndedException() => l.sessionEndedOnServer,
    ClientCertificateRequiredException(
      :final certificatePresented,
      :final definitive,
    ) =>
      certificatePresented
          ? l.errorClientCertRejected
          : definitive
              ? l.errorClientCertRequired
              : l.errorClientCertMaybeRequired,
    NewDeviceVerificationRequiredException() =>
      l.errorNewDeviceVerificationRequired,
    InvalidNewDeviceOtpException() => l.errorInvalidNewDeviceOtp,
    AuthRequestSupersededException() => l.errorAuthRequestSuperseded,
    AuthRequestAlreadyAnsweredException() => l.errorAuthRequestAlreadyAnswered,
    AuthRequestNotFoundException() => l.errorAuthRequestNotFound,
    ClientVersionRejectedException() => l.errorClientVersionRejected,
    MissingUserKeyException() => l.errorMissingUserKey,
    KdfTooWeakException() => l.errorKdfTooWeak,
    UnsupportedKdfException() => l.errorUnsupportedKdf,
    ServerException() => _formatServerException(e, l),
  };
}

String _formatServerException(ServerException e, AppLocalizations l) {
  final m = e.serverMessage;
  if (m != null && m.isNotEmpty && !_isTechnicalMessage(m)) {
    final lower = m.toLowerCase();
    if (lower == 'invalid_grant' || lower == 'invalid grant') {
      return l.errorInvalidCredentials;
    }
    return m;
  }
  return _fallbackForStatus(e.statusCode, l);
}

String _formatClientCertError(ClientCertException e, AppLocalizations l) {
  return switch (e) {
    ClientCertBadPasswordException() => l.errorClientCertBadPassword,
    ClientCertUnsupportedFormatException() => l.errorClientCertUnsupported,
    ClientCertInvalidCaException() => l.errorClientCertInvalidCa,
  };
}

String _formatDioError(DioException e, AppLocalizations l) {
  final inner = e.error;
  if (inner is ApiException) return _formatApiError(inner, l);

  // If we got an HTTP response, always parse the body.
  final response = e.response;
  if (response != null) {
    return _formatApiError(
      ApiException.fromResponse(
        response.statusCode,
        response.data,
        headers: response.headers.map,
      ),
      l,
    );
  }

  // mTLS handshake failures.
  final cert = ClientCertificateRequiredException.classify(inner ?? e);
  if (cert != null) return _formatApiError(cert, l);

  // Custom message set by our API layer (no response attached)
  if (e.message != null &&
      e.message!.isNotEmpty &&
      !_isDefaultDioMessage(e.message!)) {
    return e.message!;
  }

  // Network-level errors (no response from server)
  return _formatNetworkError(e, l);
}

/// Default Dio messages that should never be shown to the user.
bool _isDefaultDioMessage(String msg) {
  return msg.startsWith('The ') ||
      msg.startsWith('This exception') ||
      msg.contains('RequestOptions.validateStatus');
}

/// Check if a server error message is too technical / ugly for users.
bool _isTechnicalMessage(String msg) {
  final lower = msg.toLowerCase();
  return lower.contains('exception') ||
      lower.contains('stacktrace') ||
      lower.contains('at line') ||
      lower.contains('null reference') ||
      msg.length > 200;
}

String _fallbackForStatus(int? status, AppLocalizations l) {
  if (status == null) return l.errorCannotConnect;
  if (status == 400) return l.errorInvalidRequest;
  if (status == 401) return l.errorSessionExpired;
  if (status == 403) return l.errorAccessDenied;
  if (status == 404) return l.errorEndpointNotFound;
  if (status == 429) return l.errorTooManyAttempts;
  if (status >= 500) return l.errorServerRetry(status);
  return l.errorServer(status);
}

String _formatNetworkError(DioException e, AppLocalizations l) {
  final msg = e.message ?? '';
  final errorStr = e.error?.toString() ?? '';
  final combined = '$msg $errorStr';

  // DNS resolution failure
  if (combined.contains('resolve host') ||
      combined.contains('getaddrinfo') ||
      combined.contains('Failed host lookup')) {
    return l.errorCannotResolve;
  }

  // Connection timeout
  if (e.type == DioExceptionType.connectionTimeout ||
      e.type == DioExceptionType.receiveTimeout ||
      e.type == DioExceptionType.sendTimeout ||
      combined.contains('timed out')) {
    return l.errorConnectionTimeout;
  }

  // SSL/TLS errors (server certificate)
  if (e.type == DioExceptionType.badCertificate ||
      combined.contains('CERTIFICATE_VERIFY_FAILED') ||
      combined.contains('HandshakeException')) {
    return l.errorSslCertificate;
  }

  // Connection refused / unreachable
  if (e.type == DioExceptionType.connectionError ||
      combined.contains('SocketException') ||
      combined.contains('Connection refused') ||
      combined.contains('Connection reset') ||
      combined.contains('Network is unreachable') ||
      combined.contains('No route to host') ||
      combined.contains('Software caused connection abort')) {
    return l.errorCannotConnect;
  }

  // Other SSL/TLS errors
  if (combined.contains('certificate') ||
      combined.contains('CERTIFICATE') ||
      combined.contains('SSL') ||
      combined.contains('TLS')) {
    return l.errorSslCertificate;
  }

  // Request cancelled
  if (e.type == DioExceptionType.cancel) {
    return l.errorRequestCancelled;
  }

  // Fallback: if everything else, show a generic connection error
  // rather than the raw DioException dump
  return l.errorCannotConnect;
}

/// Returns true if the error represents a network/connectivity issue
/// (as opposed to a server-side or app-level error).
bool isNetworkError(Object e) {
  if (e is ApiException) return false;
  if (e is SocketException) return true;
  if (e is DioException) {
    if (e.response != null) {
      // Got a response from the server — not a network issue
      return false;
    }
    final inner = e.error;
    if (inner is ApiException) return false;
    if (ClientCertificateRequiredException.classify(inner ?? e) != null) {
      return false;
    }
    // No response: connection error, timeout, DNS, etc.
    return true;
  }
  final msg = e.toString();
  return msg.contains('SocketException') ||
      msg.contains('Connection refused') ||
      msg.contains('Failed host lookup') ||
      msg.contains('Network is unreachable');
}

/// Returns true if the error indicates the session/token has expired
/// and the user must re-authenticate.
bool isAuthError(Object e) {
  if (e is SessionEndedException) return true;
  if (e is ApiException && e.statusCode == 401) return true;
  if (e is DioException) {
    if (e.error is SessionEndedException) return true;
    if (e.response?.statusCode == 401) return true;
  }
  if (e.toString().contains('Setup not completed')) return true;
  return false;
}

/// The server ended the session (dead refresh token / signed out): the app
/// must return to the login screen (keeping device_id).
bool isSessionEndedError(Object e) =>
    e is SessionEndedException ||
    (e is DioException && e.error is SessionEndedException);

/// The server requires (or rejected) a client certificate.
bool isClientCertificateError(Object e) =>
    e is ClientCertificateRequiredException ||
    (e is DioException && e.error is ClientCertificateRequiredException);

/// Localised text for a failed cloud-sync sign-in, or null when there is
/// nothing to tell (the user cancelled the Google/Apple sheet).
String? describeCloudSyncError(Object e, AppLocalizations l) {
  if (e is AuthException) {
    return switch (e.failure) {
      AuthFailure.cancelled => null,
      AuthFailure.notConfigured => l.cloudSyncErrorNotConfigured,
      AuthFailure.unsupported => l.cloudSyncErrorUnsupported(e.provider),
      AuthFailure.missingToken => l.cloudSyncErrorNoToken(e.provider),
      AuthFailure.emailInUse => l.cloudSyncErrorEmailInUse(e.provider),
      AuthFailure.wrongAccount => l.cloudSyncErrorWrongAccount(e.provider),
      AuthFailure.deleteFailed =>
        l.cloudSyncDeleteErrorFailed(e.detail ?? 'unknown'),
      AuthFailure.failed => e.detail == null
          ? l.cloudSyncErrorGeneric
          : l.cloudSyncErrorFailed(e.provider, e.detail!),
    };
  }
  if (e is TimeoutException) return l.cloudSyncErrorTimeout;
  if (isNetworkError(e)) return l.errorCannotConnect;
  return l.cloudSyncErrorGeneric;
}

/// Localised text for a failed cloud-sync account deletion, or null when the
/// user cancelled the confirming sign-in.
String? describeCloudDeleteError(Object e, AppLocalizations l) {
  if (e is TimeoutException) return l.cloudSyncDeleteErrorTimeout;
  if (e is AuthException) return describeCloudSyncError(e, l);
  if (isNetworkError(e)) return l.errorCannotConnect;
  return l.cloudSyncDeleteErrorFailed('unknown');
}
