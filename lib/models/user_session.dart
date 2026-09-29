import 'server_environment.dart';

/// Persisted session state (tokens + server info).
/// The actual UserKey is NOT here — it's in secure storage separately.
class UserSession {
  final String email;

  /// Base URL of the deployment (see [ServerEnvironment.baseUrl]); cloud
  /// sessions store `https://vault.bitwarden.com` / `https://vault.bitwarden.eu`.
  final String serverUrl;
  final String accessToken;
  final String refreshToken;
  final DateTime accessTokenExpiry;

  const UserSession({
    required this.email,
    required this.serverUrl,
    required this.accessToken,
    required this.refreshToken,
    required this.accessTokenExpiry,
  });

  /// The service URLs for [serverUrl].
  ServerEnvironment get environment => ServerEnvironment.fromUrl(serverUrl);

  bool get isAccessTokenExpired => expiresWithin(const Duration(minutes: 1));

  /// True when the access token expires within [margin] (or already has).
  bool expiresWithin(Duration margin, {DateTime? now}) =>
      (now ?? DateTime.now()).isAfter(accessTokenExpiry.subtract(margin));

  Map<String, dynamic> toJson() => {
        'email': email,
        'serverUrl': serverUrl,
        'accessToken': accessToken,
        'refreshToken': refreshToken,
        'accessTokenExpiry': accessTokenExpiry.toIso8601String(),
      };

  factory UserSession.fromJson(Map<String, dynamic> json) => UserSession(
        email: json['email'] as String,
        serverUrl: json['serverUrl'] as String,
        accessToken: json['accessToken'] as String,
        refreshToken: json['refreshToken'] as String,
        accessTokenExpiry: DateTime.parse(json['accessTokenExpiry'] as String),
      );

  UserSession copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? accessTokenExpiry,
  }) =>
      UserSession(
        email: email,
        serverUrl: serverUrl,
        accessToken: accessToken ?? this.accessToken,
        refreshToken: refreshToken ?? this.refreshToken,
        accessTokenExpiry: accessTokenExpiry ?? this.accessTokenExpiry,
      );
}
