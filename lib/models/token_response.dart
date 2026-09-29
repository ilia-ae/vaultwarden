import 'api_error.dart';
import 'json_util.dart';
import 'kdf_params.dart';

/// `UserDecryptionOptions.MasterPasswordUnlock` from a token response.
class MasterPasswordUnlock {
  const MasterPasswordUnlock({
    required this.masterKeyWrappedUserKey,
    this.kdf,
    this.salt,
  });

  /// The user key encrypted with the (stretched) master key — a CipherString.
  final String masterKeyWrappedUserKey;

  /// KDF the server says this account uses (salt included), if parseable.
  final KdfParams? kdf;

  /// Master-password salt (bitwarden.com may differ from the e-mail after a
  /// self-service e-mail change; Vaultwarden sends the e-mail).
  final String? salt;

  static MasterPasswordUnlock? tryParse(Object? json) {
    if (json is! Map) return null;
    final key = jsonNonEmptyString(json, 'MasterKeyEncryptedUserKey') ??
        jsonNonEmptyString(json, 'MasterKeyWrappedUserKey');
    if (key == null) return null;
    return MasterPasswordUnlock(
      masterKeyWrappedUserKey: key,
      kdf: KdfParams.tryFromMasterPasswordUnlock(json),
      salt: jsonNonEmptyString(json, 'Salt'),
    );
  }
}

/// Parsed `/identity/connect/token` response (password or refresh grant).
class TokenResponse {
  const TokenResponse({
    required this.accessToken,
    required this.expiresIn,
    this.refreshToken,
    this.key,
    this.masterPasswordUnlock,
    this.twoFactorToken,
    this.privateKey,
    this.hasMasterPassword,
    this.raw = const {},
  });

  final String accessToken;
  final String? refreshToken;

  /// Seconds (defaults to 3600 when absent).
  final int expiresIn;

  /// Deprecated top-level `Key` (protected user key), if sent.
  final String? key;

  final MasterPasswordUnlock? masterPasswordUnlock;

  /// 2FA "remember this device" token (provider 5) — store per server+email.
  final String? twoFactorToken;
  final String? privateKey;
  final bool? hasMasterPassword;
  final Map<String, dynamic> raw;

  /// Throws [FormatException] when there is no `access_token`.
  factory TokenResponse.fromJson(Map<String, dynamic> json) {
    final access = jsonNonEmptyString(json, 'access_token');
    if (access == null) {
      throw const FormatException('Token response without access_token');
    }
    final options = jsonGet(json, 'UserDecryptionOptions');
    return TokenResponse(
      accessToken: access,
      refreshToken: jsonNonEmptyString(json, 'refresh_token'),
      expiresIn: jsonInt(json, 'expires_in') ?? 3600,
      key: jsonNonEmptyString(json, 'Key'),
      masterPasswordUnlock: MasterPasswordUnlock.tryParse(
          jsonGet(options, 'MasterPasswordUnlock')),
      twoFactorToken: jsonNonEmptyString(json, 'TwoFactorToken'),
      privateKey: jsonNonEmptyString(json, 'PrivateKey'),
      hasMasterPassword: jsonBool(options, 'HasMasterPassword'),
      raw: json,
    );
  }

  /// Protected user key: `MasterPasswordUnlock.MasterKeyEncryptedUserKey`
  /// (current) falling back to the deprecated top-level `Key`.
  String? get protectedUserKey =>
      masterPasswordUnlock?.masterKeyWrappedUserKey ?? key;

  /// Like [protectedUserKey] but throws [MissingUserKeyException] (A8).
  String requireProtectedUserKey() {
    final k = protectedUserKey;
    if (k == null) throw const MissingUserKeyException();
    return k;
  }

  /// Access-token expiry computed from [expiresIn].
  DateTime expiryFrom(DateTime now) => now.add(Duration(seconds: expiresIn));
}
