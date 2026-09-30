/// Why a cloud-sync sign-in (or account deletion) failed; the UI localises it
/// (see `describeCloudSyncError`).
enum AuthFailure {
  /// The user closed the Google/Apple sheet: nothing to report.
  cancelled,

  /// This build has no Google web client ID.
  notConfigured,

  /// The provider's sign-in is not available on this platform.
  unsupported,

  /// Google answered without an ID token.
  missingToken,

  /// The e-mail already belongs to an account with another provider.
  emailInUse,

  /// Re-authentication picked a different account than the signed-in one.
  wrongAccount,

  /// Deleting the account (or its data) failed after re-authentication;
  /// [AuthException.detail] holds the Firebase code.
  deleteFailed,

  /// Anything else; [AuthException.detail] holds the provider's code.
  failed,
}

/// Cloud-sync sign-in failure. [message] is an English description for logs
/// only — show `describeCloudSyncError(e, l10n)` to the user.
class AuthException implements Exception {
  AuthException(
    this.failure, {
    this.provider = '',
    this.detail,
    String? message,
  }) : message = message ??
            '$provider sign-in: ${failure.name}'
                '${detail == null ? '' : ' ($detail)'}';

  final AuthFailure failure;

  /// "Google" or "Apple" (brand names, not translated).
  final String provider;

  /// Provider / Firebase error code, if any.
  final String? detail;

  final String message;

  @override
  String toString() => message;
}
