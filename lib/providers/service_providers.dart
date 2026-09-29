import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/biometric_service.dart';
import '../services/client_cert_service.dart';
import '../services/crypto_service.dart';
import '../services/notification_service.dart';
import '../services/secure_storage_service.dart';
import '../services/vault_api.dart';

final cryptoServiceProvider = Provider<CryptoService>((_) => CryptoService());

final biometricServiceProvider =
    Provider<BiometricService>((_) => BiometricService());

final secureStorageProvider =
    Provider<SecureStorageService>((_) => SecureStorageService());

/// Per-server client certificates (mTLS, F1). One shared instance so an
/// import reaches both the REST client and the notifications hub.
final clientCertServiceProvider =
    Provider<ClientCertService>((_) => ClientCertService.instance);

final apiServiceProvider = Provider<VaultApiService>((ref) {
  final api = VaultApiService(
    ref.read(secureStorageProvider),
    clientCerts: ref.read(clientCertServiceProvider),
    crypto: ref.read(cryptoServiceProvider),
  );
  ref.onDispose(api.dispose);
  return api;
});

/// The notifications hub asks the API for a valid (refreshed when needed)
/// access token on every connect, so realtime survives token expiry (F10).
final notificationServiceProvider = Provider<NotificationService>((ref) {
  final api = ref.read(apiServiceProvider);
  final hub = NotificationService(
    tokenProvider: ({bool forceRefresh = false}) =>
        api.getValidAccessToken(forceRefresh: forceRefresh),
    clientCerts: ref.read(clientCertServiceProvider),
  );
  ref.onDispose(hub.dispose);
  return hub;
});
