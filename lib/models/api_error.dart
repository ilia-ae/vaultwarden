import 'dart:io';

import 'json_util.dart';

/// Stable codes for [ApiException]s, for localisation in the UI layer.
enum ApiErrorCode {
  twoFactorRequired,
  invalidTwoFactorCode,
  newDeviceVerificationRequired,
  invalidNewDeviceOtp,
  invalidCredentials,
  rateLimited,
  authRequestSuperseded,
  authRequestAlreadyAnswered,
  authRequestNotFound,
  sessionEnded,
  clientCertificateRequired,
  clientVersionRejected,
  missingUserKey,
  kdfTooWeak,
  unsupportedKdf,
  server,
}

/// Why a session was ended (see [SessionEndedException]).
enum SessionEndReason {
  /// The refresh token was rejected with `invalid_grant` (password change,
  /// "deauthorize sessions", key rotation, security-stamp reset, expiry).
  refreshTokenRejected,

  /// The refresh request failed (non-transient) and the API answered 401.
  unauthorizedAfterRefreshFailure,
}

/// Base class of every typed error the app's server layer throws.
///
/// Network-level failures without an HTTP response stay `DioException`s
/// (except TLS/mTLS failures, see [ClientCertificateRequiredException]).
sealed class ApiException implements Exception {
  const ApiException({this.statusCode, this.serverMessage});

  /// HTTP status, when the error came from an HTTP response.
  final int? statusCode;

  /// First non-empty human message from the server body (F9), verbatim.
  final String? serverMessage;

  ApiErrorCode get code;

  @override
  String toString() {
    final status = statusCode == null ? '' : ' ($statusCode)';
    final msg = serverMessage == null ? '' : ': $serverMessage';
    return '$runtimeType$status$msg';
  }

  /// Maps an HTTP error response to a typed exception.
  ///
  /// [body] is the decoded JSON (or raw string) body. [headers] are used for
  /// `Retry-After` on 429.
  static ApiException fromResponse(
    int? statusCode,
    Object? body, {
    Map<String, List<String>>? headers,
  }) {
    final data = decodeJsonBody(body);
    final message = extractServerMessage(data);
    final lower = (message ?? '').toLowerCase();
    final errorCode = (jsonString(data, 'error') ?? '').toLowerCase();
    final description =
        (jsonString(data, 'error_description') ?? '').toLowerCase();

    if (statusCode == 429) {
      return RateLimitedException(
        statusCode: statusCode,
        serverMessage: message,
        retryAfter: _retryAfter(headers),
      );
    }

    if (_hasTwoFactorProviders(data) ||
        description.contains('two factor required') ||
        lower.contains('two factor required')) {
      return TwoFactorRequiredException(
        availableProviders: _parseTwoFactorProviders(data),
        providerData: _parseProviderData(data),
        statusCode: statusCode,
        serverMessage: message,
      );
    }

    if (lower.contains('new device verification required')) {
      return NewDeviceVerificationRequiredException(
        statusCode: statusCode,
        serverMessage: message,
      );
    }
    if (lower.contains('invalid new device otp')) {
      return InvalidNewDeviceOtpException(
        statusCode: statusCode,
        serverMessage: message,
      );
    }
    if (errorCode == 'version_header_missing' ||
        errorCode == 'invalid_client_version') {
      return ClientVersionRejectedException(
        statusCode: statusCode,
        serverMessage: message,
      );
    }
    if (_isInvalidTwoFactorCode(lower)) {
      return InvalidTwoFactorCodeException(
        statusCode: statusCode,
        serverMessage: message,
      );
    }
    if (lower.contains('no longer valid') ||
        lower.contains('approve the most recent request')) {
      return AuthRequestSupersededException(
        statusCode: statusCode,
        serverMessage: message,
      );
    }
    if (lower.contains('same device already exists')) {
      return AuthRequestAlreadyAnsweredException(
        statusCode: statusCode,
        serverMessage: message,
      );
    }
    if (lower.contains("authrequest doesn't exist") ||
        lower.contains('auth request not found')) {
      return AuthRequestNotFoundException(
        statusCode: statusCode,
        serverMessage: message,
      );
    }
    if (lower.contains('username or password is incorrect')) {
      return InvalidCredentialsException(
        statusCode: statusCode,
        serverMessage: message,
      );
    }
    return ServerException(statusCode: statusCode, serverMessage: message);
  }
}

/// The server demands a second factor. Re-send the token request with
/// `twoFactorProvider` + `twoFactorToken`.
final class TwoFactorRequiredException extends ApiException {
  const TwoFactorRequiredException({
    required this.availableProviders,
    this.providerData = const {},
    super.statusCode,
    super.serverMessage,
  });

  /// Provider ids in server order: 0 Authenticator (TOTP), 1 Email, 2 Duo,
  /// 3 YubiKey OTP, 4 U2F, 5 Remember, 6 OrganizationDuo, 7 WebAuthn,
  /// 8 RecoveryCode.
  final List<int> availableProviders;

  /// Per-provider data from `TwoFactorProviders2` (e.g. `{1: {Email: 'j***@x'}}`).
  final Map<int, Object?> providerData;

  bool get hasTotp => availableProviders.contains(0);
  bool get hasEmail => availableProviders.contains(1);

  /// Obscured e-mail address the server will send the code to, if known.
  String? get obscuredEmail => jsonString(providerData[1], 'Email');

  @override
  ApiErrorCode get code => ApiErrorCode.twoFactorRequired;

  @override
  String toString() =>
      'TwoFactorRequiredException(providers: $availableProviders)';
}

/// Wrong / expired 2FA code (TOTP, e-mail, YubiKey, recovery code). The UI
/// should reopen the code input.
final class InvalidTwoFactorCodeException extends ApiException {
  const InvalidTwoFactorCodeException({super.statusCode, super.serverMessage});
  @override
  ApiErrorCode get code => ApiErrorCode.invalidTwoFactorCode;
}

/// bitwarden.com new-device verification: an e-mailed OTP must be sent back
/// as `newDeviceOtp` with the same `deviceIdentifier`.
final class NewDeviceVerificationRequiredException extends ApiException {
  const NewDeviceVerificationRequiredException({
    super.statusCode,
    super.serverMessage,
  });
  @override
  ApiErrorCode get code => ApiErrorCode.newDeviceVerificationRequired;
}

/// The new-device OTP was wrong or expired — ask for it again.
final class InvalidNewDeviceOtpException extends ApiException {
  const InvalidNewDeviceOtpException({super.statusCode, super.serverMessage});
  @override
  ApiErrorCode get code => ApiErrorCode.invalidNewDeviceOtp;
}

/// "Username or password is incorrect".
final class InvalidCredentialsException extends ApiException {
  const InvalidCredentialsException({super.statusCode, super.serverMessage});
  @override
  ApiErrorCode get code => ApiErrorCode.invalidCredentials;
}

/// HTTP 429.
final class RateLimitedException extends ApiException {
  const RateLimitedException({
    super.statusCode,
    super.serverMessage,
    this.retryAfter,
  });

  /// From the `Retry-After` header, when the server sent one.
  final Duration? retryAfter;

  @override
  ApiErrorCode get code => ApiErrorCode.rateLimited;
}

/// bitwarden.com: "This request is no longer valid. Make sure to approve the
/// most recent request." — a newer request from the same device exists.
final class AuthRequestSupersededException extends ApiException {
  const AuthRequestSupersededException({super.statusCode, super.serverMessage});
  @override
  ApiErrorCode get code => ApiErrorCode.authRequestSuperseded;
}

/// "An authentication request with the same device already exists" — the
/// request was already approved/denied (here or elsewhere).
final class AuthRequestAlreadyAnsweredException extends ApiException {
  const AuthRequestAlreadyAnsweredException({
    super.statusCode,
    super.serverMessage,
  });
  @override
  ApiErrorCode get code => ApiErrorCode.authRequestAlreadyAnswered;
}

/// "AuthRequest doesn't exist" — expired/purged, denied elsewhere, or (on
/// Vaultwarden) the device check failed.
final class AuthRequestNotFoundException extends ApiException {
  const AuthRequestNotFoundException({super.statusCode, super.serverMessage});
  @override
  ApiErrorCode get code => ApiErrorCode.authRequestNotFound;
}

/// The server ended the session; the user must log in again. Keep the
/// `device_id` (see `SecureStorageService.clearSessionData`).
final class SessionEndedException extends ApiException {
  const SessionEndedException({
    required this.reason,
    super.statusCode,
    super.serverMessage,
  });

  final SessionEndReason reason;

  @override
  ApiErrorCode get code => ApiErrorCode.sessionEnded;

  @override
  String toString() => 'SessionEndedException(${reason.name})';
}

/// The TLS handshake failed in a way that points at a missing or rejected
/// client certificate (mTLS).
final class ClientCertificateRequiredException extends ApiException {
  const ClientCertificateRequiredException({
    this.certificatePresented = false,
    this.definitive = true,
    super.serverMessage,
  });

  /// Whether a client certificate was configured for this server (then the
  /// server most likely *rejected* it: wrong CA, expired, revoked).
  final bool certificatePresented;

  /// False when inferred heuristically (connection closed during TLS setup)
  /// rather than from an explicit TLS alert.
  final bool definitive;

  @override
  ApiErrorCode get code => ApiErrorCode.clientCertificateRequired;

  @override
  String toString() => 'ClientCertificateRequiredException('
      'presented: $certificatePresented, definitive: $definitive)';

  /// Classifies a transport error. Returns null if it is not an mTLS problem
  /// (e.g. the *server* certificate failed verification).
  ///
  /// [secure] = the request used TLS (https/wss); only then can a connection
  /// closed before the response headers be blamed on the client certificate.
  static ClientCertificateRequiredException? classify(
    Object error, {
    bool certificatePresented = false,
    bool secure = false,
  }) {
    final text = _describe(error);
    final upper = text.toUpperCase();
    // Server-certificate problems are not client-certificate problems.
    if (upper.contains('CERTIFICATE_VERIFY_FAILED')) return null;
    const alerts = [
      'CERTIFICATE_REQUIRED',
      'ALERT_BAD_CERTIFICATE',
      'ALERT_UNKNOWN_CA',
      'ALERT_CERTIFICATE_UNKNOWN',
      'ALERT_CERTIFICATE_EXPIRED',
      'ALERT_CERTIFICATE_REVOKED',
      'ALERT_UNSUPPORTED_CERTIFICATE',
      'ALERT_ACCESS_DENIED',
      'ALERT_HANDSHAKE_FAILURE',
    ];
    if (alerts.any(upper.contains)) {
      return ClientCertificateRequiredException(
        certificatePresented: certificatePresented,
      );
    }
    // TLS 1.3: the client finishes its side of the handshake before the
    // server checks the certificate, so a server that just drops the
    // connection shows up as "closed before full header" on the request.
    final lower = text.toLowerCase();
    if (secure && lower.contains('connection closed before full header')) {
      return ClientCertificateRequiredException(
        certificatePresented: certificatePresented,
        definitive: false,
      );
    }
    // Same situation, but the server's TCP reset overtook its TLS alert:
    // dart:io then reports a bare "Connection reset by peer" when reading
    // the response (an HttpException, not a SocketException from a write on
    // a stale connection). Only a heuristic, hence not definitive — callers
    // retry these like network errors.
    final isRead = error is HttpException || upper.contains('HTTPEXCEPTION');
    if (secure && isRead && lower.contains('connection reset by peer')) {
      return ClientCertificateRequiredException(
        certificatePresented: certificatePresented,
        definitive: false,
      );
    }
    final isHandshake = error is HandshakeException ||
        upper.contains('HANDSHAKEEXCEPTION') ||
        upper.contains('HANDSHAKE');
    if (isHandshake &&
        (lower.contains('connection reset') ||
            lower.contains('connection terminated') ||
            lower.contains('connection closed'))) {
      return ClientCertificateRequiredException(
        certificatePresented: certificatePresented,
        definitive: false,
      );
    }
    return null;
  }

  static String _describe(Object error) {
    final parts = <String>[error.runtimeType.toString(), error.toString()];
    if (error is TlsException) {
      parts.add(error.message);
      final os = error.osError;
      if (os != null) parts.add(os.message);
    }
    return parts.join(' ');
  }
}

/// bitwarden.com refused the `Bitwarden-Client-Version` header
/// (`version_header_missing` / `invalid_client_version`).
final class ClientVersionRejectedException extends ApiException {
  const ClientVersionRejectedException({super.statusCode, super.serverMessage});
  @override
  ApiErrorCode get code => ApiErrorCode.clientVersionRejected;
}

/// The token response carried neither `Key` nor
/// `UserDecryptionOptions.MasterPasswordUnlock` (e.g. SSO / TDE-only or
/// key-connector accounts, or a Vaultwarden account with an empty `akey`).
final class MissingUserKeyException extends ApiException {
  const MissingUserKeyException({super.serverMessage});
  @override
  ApiErrorCode get code => ApiErrorCode.missingUserKey;
}

/// Server-provided KDF parameters are below the official clients' minimums
/// (PBKDF2 5000 iterations; Argon2id 16 MiB, 2 iterations, 1 lane) or above
/// sane limits — refusing protects the master password from a downgrade.
final class KdfTooWeakException extends ApiException {
  const KdfTooWeakException(this.detail) : super(serverMessage: null);

  /// Technical description (not localised), e.g. `PBKDF2 iterations 1 < 5000`.
  final String detail;

  @override
  ApiErrorCode get code => ApiErrorCode.kdfTooWeak;

  @override
  String toString() => 'KdfTooWeakException($detail)';
}

/// Unknown KDF type from the server.
final class UnsupportedKdfException extends ApiException {
  const UnsupportedKdfException(this.kdfType) : super(serverMessage: null);
  final int kdfType;
  @override
  ApiErrorCode get code => ApiErrorCode.unsupportedKdf;
  @override
  String toString() => 'UnsupportedKdfException($kdfType)';
}

/// Any other HTTP error; [serverMessage] holds the server's text if any.
final class ServerException extends ApiException {
  const ServerException({super.statusCode, super.serverMessage});
  @override
  ApiErrorCode get code => ApiErrorCode.server;
}

// ── Helpers ──

/// First non-empty message of: `message`, `errorModel.message`,
/// `error_description`, `error` — keys matched case-insensitively (so both
/// Vaultwarden's `errorModel.message` and Bitwarden's `ErrorModel.Message`).
///
/// Vaultwarden always sends `"error": ""` and `"error_description": ""`, so a
/// `??` chain would stop at the empty string; this takes the first non-empty.
String? extractServerMessage(Object? body) {
  final data = decodeJsonBody(body);
  if (data is String) {
    final s = data.trim();
    // A plain-text body (proxy error page etc.) — only short ones are useful.
    if (s.isEmpty || s.length > 300 || s.startsWith('<')) return null;
    return s;
  }
  final candidates = <Object?>[
    jsonGet(data, 'message'),
    jsonPath(data, ['errorModel', 'message']),
    jsonGet(data, 'error_description'),
    jsonGet(data, 'error'),
  ];
  for (final c in candidates) {
    if (c is String && c.trim().isNotEmpty) return c.trim();
  }
  return null;
}

bool _isInvalidTwoFactorCode(String lower) =>
    lower.contains('totp') ||
    lower.contains('two-step token is invalid') ||
    lower.contains('two factor token') ||
    lower.contains('token is invalid') ||
    lower.contains('token has expired') ||
    lower.contains('yubikey') ||
    lower.contains('recovery code is incorrect');

bool _hasTwoFactorProviders(Object? data) =>
    jsonGet(data, 'TwoFactorProviders') != null ||
    jsonGet(data, 'TwoFactorProviders2') != null;

List<int> _parseTwoFactorProviders(Object? data) {
  final result = <int>[];
  final list = jsonGet(data, 'TwoFactorProviders');
  if (list is List) {
    for (final e in list) {
      final id = asInt(e);
      if (id != null && !result.contains(id)) result.add(id);
    }
  }
  final map = jsonGet(data, 'TwoFactorProviders2');
  if (map is Map) {
    for (final k in map.keys) {
      final id = asInt(k);
      if (id != null && !result.contains(id)) result.add(id);
    }
  }
  // "Two factor required" without a list: assume TOTP.
  if (result.isEmpty) result.add(0);
  return result;
}

Map<int, Object?> _parseProviderData(Object? data) {
  final map = jsonGet(data, 'TwoFactorProviders2');
  if (map is! Map) return const {};
  return {
    for (final e in map.entries)
      if (asInt(e.key) != null) asInt(e.key)!: e.value,
  };
}

Duration? _retryAfter(Map<String, List<String>>? headers) {
  if (headers == null) return null;
  for (final e in headers.entries) {
    if (e.key.toLowerCase() != 'retry-after' || e.value.isEmpty) continue;
    final v = e.value.first.trim();
    final seconds = int.tryParse(v);
    if (seconds != null) return Duration(seconds: seconds);
    try {
      final at = HttpDate.parse(v);
      final d = at.difference(DateTime.now().toUtc());
      return d.isNegative ? Duration.zero : d;
    } catch (_) {
      return null;
    }
  }
  return null;
}
