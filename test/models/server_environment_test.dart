import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/models/server_environment.dart';

void main() {
  group('ServerEnvironment (F16)', () {
    test('US preset uses separate hosts', () {
      const env = ServerEnvironment.us;
      expect(env.apiUrl, 'https://api.bitwarden.com');
      expect(env.identityUrl, 'https://identity.bitwarden.com');
      expect(
        env.hubUri(accessToken: 't').toString(),
        'wss://notifications.bitwarden.com/hub?access_token=t',
      );
      expect(env.isCloud, isTrue);
      expect(env.storageScope, 'bitwarden.com');
    });

    test('EU preset', () {
      const env = ServerEnvironment.eu;
      expect(env.apiUrl, 'https://api.bitwarden.eu');
      expect(env.identityUrl, 'https://identity.bitwarden.eu');
      expect(
        env.hubUri().toString(),
        'wss://notifications.bitwarden.eu/hub',
      );
    });

    test('fromUrl recognises cloud hosts', () {
      for (final url in [
        'https://vault.bitwarden.com',
        'https://vault.bitwarden.com/',
        'vault.bitwarden.com',
        'https://bitwarden.com',
      ]) {
        expect(ServerEnvironment.fromUrl(url), ServerEnvironment.us,
            reason: url);
      }
      expect(
        ServerEnvironment.fromUrl('https://vault.bitwarden.eu'),
        ServerEnvironment.eu,
      );
    });

    test('self-hosted keeps custom port and path (compatible_ok)', () {
      final env = ServerEnvironment.fromUrl('https://Vault-Test.ilia.ae:2053/');
      expect(env.region, ServerRegion.selfHosted);
      expect(env.baseUrl, 'https://vault-test.ilia.ae:2053');
      expect(env.apiUrl, 'https://vault-test.ilia.ae:2053/api');
      expect(env.identityUrl, 'https://vault-test.ilia.ae:2053/identity');
      expect(
        env.hubUri(accessToken: 'a b').toString(),
        'wss://vault-test.ilia.ae:2053/notifications/hub?access_token=a+b',
      );
      expect(env.origin, 'https://vault-test.ilia.ae:2053');
      expect(env.storageScope, 'https://vault-test.ilia.ae:2053');

      final withPath = ServerEnvironment.fromUrl('https://example.com/vault//');
      expect(withPath.apiUrl, 'https://example.com/vault/api');
      expect(
        withPath.hubUri().toString(),
        'wss://example.com/vault/notifications/hub',
      );
    });

    test(
        'http → ws, default scheme https, bitwarden.com with a path is self-hosted',
        () {
      expect(
        ServerEnvironment.fromUrl('http://127.0.0.1:8080').hubUri().toString(),
        'ws://127.0.0.1:8080/notifications/hub',
      );
      expect(
        ServerEnvironment.fromUrl('vault.example.com').baseUrl,
        'https://vault.example.com',
      );
      expect(
        ServerEnvironment.fromUrl('https://vault.bitwarden.com/x').region,
        ServerRegion.selfHosted,
      );
    });

    test('IPv6 literals keep their brackets', () {
      final env = ServerEnvironment.fromUrl('https://[FD00::1]:2053/');
      expect(env.baseUrl, 'https://[fd00::1]:2053');
      expect(env.apiUrl, 'https://[fd00::1]:2053/api');
      expect(Uri.parse(env.apiUrl).port, 2053);
      expect(
        env.hubUri(accessToken: 't').toString(),
        'wss://[fd00::1]:2053/notifications/hub?access_token=t',
      );
      expect(env.origin, 'https://[fd00::1]:2053');
      expect(
        ServerEnvironment.normalizeBaseUrl('[::1]/vault/'),
        'https://[::1]/vault',
      );
    });

    test('plaintext http is flagged unless it stays on the device', () {
      for (final url in [
        'http://vault.example.com',
        'http://192.168.1.10:8080',
        'http://[fd00::1]:8080',
      ]) {
        expect(ServerEnvironment.isPlaintextRemote(url), isTrue, reason: url);
      }
      for (final url in [
        'https://vault.example.com',
        'vault.example.com',
        'http://127.0.0.1:18080',
        'http://localhost:8080',
        'http://[::1]:8080',
      ]) {
        expect(ServerEnvironment.isPlaintextRemote(url), isFalse, reason: url);
      }
    });

    test('invalid URLs throw FormatException', () {
      for (final bad in ['', '   ', 'ftp://x.com', 'https://']) {
        expect(
          () => ServerEnvironment.fromUrl(bad),
          throwsA(isA<FormatException>()),
          reason: bad,
        );
      }
    });
  });
}
