import 'dart:io';

/// Which Bitwarden-compatible deployment the app talks to.
enum ServerRegion {
  /// bitwarden.com (US cloud).
  us,

  /// bitwarden.eu (EU cloud).
  eu,

  /// Self-hosted Vaultwarden / Bitwarden: one base URL, custom port/path kept.
  selfHosted,
}

/// Service URLs of a deployment.
///
/// Cloud regions use separate hosts (`api.`, `identity.`, `notifications.`),
/// exactly like the official clients (default-environment.service.ts).
/// Self-hosted servers use one base URL: `{base}/api`, `{base}/identity`,
/// `{base}/notifications`.
class ServerEnvironment {
  const ServerEnvironment._({
    required this.region,
    required this.baseUrl,
    required this.apiUrl,
    required this.identityUrl,
    required this.notificationsUrl,
  });

  final ServerRegion region;

  /// User-facing URL stored in the session (`UserSession.serverUrl`):
  /// `https://vault.bitwarden.com`, `https://vault.bitwarden.eu`, or the
  /// normalised self-hosted base URL (no trailing slash).
  final String baseUrl;

  /// REST API root, no trailing slash (e.g. `https://api.bitwarden.com`,
  /// `https://host:2053/api`).
  final String apiUrl;

  /// Identity root, no trailing slash (e.g. `https://identity.bitwarden.com`).
  final String identityUrl;

  /// Notifications root; the SignalR hub is `{notificationsUrl}/hub`.
  final String notificationsUrl;

  static const us = ServerEnvironment._(
    region: ServerRegion.us,
    baseUrl: 'https://vault.bitwarden.com',
    apiUrl: 'https://api.bitwarden.com',
    identityUrl: 'https://identity.bitwarden.com',
    notificationsUrl: 'https://notifications.bitwarden.com',
  );

  static const eu = ServerEnvironment._(
    region: ServerRegion.eu,
    baseUrl: 'https://vault.bitwarden.eu',
    apiUrl: 'https://api.bitwarden.eu',
    identityUrl: 'https://identity.bitwarden.eu',
    notificationsUrl: 'https://notifications.bitwarden.eu',
  );

  /// Cloud presets for a server picker.
  static const presets = [us, eu];

  static const _usHosts = {
    'bitwarden.com',
    'vault.bitwarden.com',
    'api.bitwarden.com',
    'identity.bitwarden.com',
    'notifications.bitwarden.com',
  };
  static const _euHosts = {
    'bitwarden.eu',
    'vault.bitwarden.eu',
    'api.bitwarden.eu',
    'identity.bitwarden.eu',
    'notifications.bitwarden.eu',
  };

  /// A self-hosted deployment at [url] (scheme defaults to https; port and
  /// path are kept). Throws [FormatException] for unusable input.
  factory ServerEnvironment.selfHosted(String url) {
    final base = normalizeBaseUrl(url);
    return ServerEnvironment._(
      region: ServerRegion.selfHosted,
      baseUrl: base,
      apiUrl: '$base/api',
      identityUrl: '$base/identity',
      notificationsUrl: '$base/notifications',
    );
  }

  /// Resolves a stored/entered URL: bitwarden.com / bitwarden.eu hosts map to
  /// the cloud presets, everything else is self-hosted.
  factory ServerEnvironment.fromUrl(String url) {
    final base = normalizeBaseUrl(url);
    final uri = Uri.parse(base);
    final path = uri.path;
    if (uri.scheme == 'https' && (path.isEmpty || path == '/')) {
      if (_usHosts.contains(uri.host)) return us;
      if (_euHosts.contains(uri.host)) return eu;
    }
    return ServerEnvironment.selfHosted(base);
  }

  /// `https://Host:2053/vault/` → `https://host:2053/vault`. Adds `https://`
  /// when no scheme is given; drops query/fragment and trailing slashes.
  static String normalizeBaseUrl(String url) {
    var s = url.trim();
    if (s.isEmpty) throw const FormatException('Empty server URL');
    if (!s.contains('://')) s = 'https://$s';
    final uri = Uri.tryParse(s);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      throw FormatException('Invalid server URL', url);
    }
    final path = uri.path.replaceAll(RegExp(r'/+$'), '');
    final port = uri.hasPort ? ':${uri.port}' : '';
    // `Uri.host` drops the brackets of an IPv6 literal; put them back or
    // the port would be read as part of the address.
    final lower = uri.host.toLowerCase();
    final host = lower.contains(':') ? '[$lower]' : lower;
    return '${uri.scheme}://$host$port$path';
  }

  /// True for an `http://` URL whose host is not the device itself: the
  /// master-password hash, tokens and approvals would travel unencrypted.
  /// Throws [FormatException] like [normalizeBaseUrl].
  static bool isPlaintextRemote(String url) {
    final uri = Uri.parse(normalizeBaseUrl(url));
    if (uri.scheme != 'http') return false;
    final host = uri.host;
    if (host == 'localhost' || host.endsWith('.localhost')) return false;
    final ip = InternetAddress.tryParse(host);
    return ip == null || !ip.isLoopback;
  }

  bool get isCloud => region != ServerRegion.selfHosted;

  /// `scheme://host[:port]` of the base URL — the key for per-server client
  /// certificates.
  String get origin => Uri.parse(baseUrl).origin;

  /// Stable key for per-server data (2FA remember tokens, history):
  /// `bitwarden.com`, `bitwarden.eu`, or the self-hosted base URL.
  String get storageScope => switch (region) {
        ServerRegion.us => 'bitwarden.com',
        ServerRegion.eu => 'bitwarden.eu',
        ServerRegion.selfHosted => baseUrl,
      };

  /// SignalR hub URL (`wss://…/hub`) — custom port and path are kept.
  Uri hubUri({String? accessToken}) {
    final u = Uri.parse('$notificationsUrl/hub');
    return u.replace(
      scheme: u.scheme == 'https' ? 'wss' : 'ws',
      queryParameters:
          accessToken == null ? null : {'access_token': accessToken},
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ServerEnvironment &&
      other.region == region &&
      other.baseUrl == baseUrl;

  @override
  int get hashCode => Object.hash(region, baseUrl);

  @override
  String toString() => 'ServerEnvironment(${region.name}, $baseUrl)';
}
