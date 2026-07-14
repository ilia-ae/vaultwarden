import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/auth_request.dart';
import '../app.dart';
import '../demo_fixtures.dart';
import '../utils/constants.dart';
import '../utils/wordlist.dart';
import 'service_providers.dart';
import 'session_provider.dart';

final authRequestsProvider =
    AsyncNotifierProvider<AuthRequestsNotifier, List<AuthRequest>>(
  AuthRequestsNotifier.new,
);

/// Local history of approved/denied requests.
final historyProvider =
    StateNotifierProvider<HistoryNotifier, List<HistoryEntry>>(
  (ref) => HistoryNotifier(),
);

class AuthRequestsNotifier extends AsyncNotifier<List<AuthRequest>> {
  Timer? _pollTimer;
  StreamSubscription<int>? _notificationSub;

  @override
  Future<List<AuthRequest>> build() async {
    // Demo: serve the fixture list, no polling, no WebSocket, no API.
    if (demoActive) return demoPendingRequests();

    ref.onDispose(() {
      _pollTimer?.cancel();
      _notificationSub?.cancel();
    });

    _startListening();
    return _fetchRequests();
  }

  Future<List<AuthRequest>> _fetchRequests() async {
    final api = ref.read(apiServiceProvider);
    final session = ref.read(sessionProvider).value;
    if (session == null) return [];

    final requests = await api.getPendingRequests();
    final crypto = ref.read(cryptoServiceProvider);

    return requests.map((r) {
      final fingerprint = crypto.generateFingerprintPhrase(
        r.publicKey,
        session.email,
        effWordlist,
      );
      return r.copyWith(fingerprint: fingerprint);
    }).toList();
  }

  void _startListening() {
    final notifications = ref.read(notificationServiceProvider);

    _notificationSub = notifications.onNotification.listen((type) {
      if (type == kAuthRequestNotificationType) {
        _silentRefresh();
      }
    });

    final session = ref.read(sessionProvider).value;
    if (session != null) {
      notifications.connect(session.serverUrl, session.accessToken);
    }

    _startPollTimer();
  }

  void _startPollTimer() {
    _pollTimer?.cancel();
    final pollSeconds = ref.read(pollIntervalProvider);
    _pollTimer = Timer.periodic(
      Duration(seconds: pollSeconds),
      (_) => _silentRefresh(),
    );
  }

  /// Call when app goes to background — stop polling + WebSocket.
  void pause() {
    if (demoActive) return;
    _pollTimer?.cancel();
    _pollTimer = null;
    ref.read(notificationServiceProvider).pause();
  }

  /// Call when app returns to foreground — refresh + restart polling + WebSocket.
  /// Retries up to 10 times with short delays if the first attempt fails,
  /// so the user doesn't have to wait for the next poll tick.
  void resume() {
    if (demoActive) return;
    ref.read(notificationServiceProvider).resume();
    _aggressiveRefresh();
    _startPollTimer();
  }

  /// Try to refresh aggressively for fast request pickup.
  /// - 10 attempts total for speed
  /// - 3 consecutive network errors → show error to user
  /// - Server error with explicit status → show error immediately
  Future<void> _aggressiveRefresh() async {
    const maxAttempts = 10;
    const maxConsecutiveErrors = 3;
    const retryDelay = Duration(seconds: 2);
    var consecutiveErrors = 0;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final requests = await _fetchRequests();
        state = AsyncData(requests);
        consecutiveErrors = 0; // Reset on success
        if (attempt < maxAttempts) {
          await Future.delayed(retryDelay);
        }
      } on DioException catch (e) {
        // Explicit server error (401, 403, etc.) — show immediately
        if (e.response?.statusCode != null) {
          state = AsyncError(e, StackTrace.current);
          return;
        }
        // Network error — count consecutive failures
        consecutiveErrors++;
        if (consecutiveErrors >= maxConsecutiveErrors) {
          state = AsyncError(e, StackTrace.current);
          return;
        }
        await Future.delayed(retryDelay);
      } catch (e) {
        consecutiveErrors++;
        if (consecutiveErrors >= maxConsecutiveErrors) {
          state = AsyncError(e, StackTrace.current);
          return;
        }
        await Future.delayed(retryDelay);
      }
    }
  }

  /// Background poll — silently ignores transient network errors.
  /// Sets error state only for auth failures (session expired).
  Future<void> _silentRefresh() async {
    try {
      final requests = await _fetchRequests();
      state = AsyncData(requests);
    } on DioException catch (e) {
      if (e.response?.statusCode == 401) {
        // Token refresh failed → session expired, show error
        state = AsyncError(e, StackTrace.current);
      }
      // Other network errors — keep old data silently
    } catch (_) {
      // Non-Dio errors — keep old data
    }
  }

  /// Manual refresh — shows error if it fails.
  Future<void> refresh() async {
    if (demoActive) return; // fixtures are static
    state = await AsyncValue.guard(_fetchRequests);
  }

  Future<void> approve(AuthRequest request) async {
    // Demo: no crypto/API — record it in history and drop it from pending.
    if (demoActive) {
      _demoResolve(request, approved: true);
      return;
    }
    final api = ref.read(apiServiceProvider);
    final crypto = ref.read(cryptoServiceProvider);
    final storage = ref.read(secureStorageProvider);
    final userKey = ref.read(userKeyProvider);

    if (userKey == null) throw StateError('Vault is locked');

    final encryptedKey =
        crypto.encryptUserKeyForApproval(userKey, request.publicKey);
    final deviceId = await storage.getOrCreateDeviceId();

    await api.respondToAuthRequest(
      requestId: request.id,
      approved: true,
      encryptedKey: encryptedKey,
      deviceId: deviceId,
    );

    ref.read(historyProvider.notifier).add(HistoryEntry(
          requestId: request.id,
          deviceType: request.requestDeviceType,
          ipAddress: request.requestIpAddress,
          fingerprint: request.fingerprint,
          approved: true,
          respondedAt: DateTime.now(),
          requestCreatedAt: request.creationDate,
        ));

    await refresh();
  }

  Future<void> deny(AuthRequest request) async {
    // Demo: no API — record it in history and drop it from pending.
    if (demoActive) {
      _demoResolve(request, approved: false);
      return;
    }
    final api = ref.read(apiServiceProvider);
    final storage = ref.read(secureStorageProvider);
    final deviceId = await storage.getOrCreateDeviceId();

    await api.respondToAuthRequest(
      requestId: request.id,
      approved: false,
      deviceId: deviceId,
    );

    ref.read(historyProvider.notifier).add(HistoryEntry(
          requestId: request.id,
          deviceType: request.requestDeviceType,
          ipAddress: request.requestIpAddress,
          fingerprint: request.fingerprint,
          approved: false,
          respondedAt: DateTime.now(),
          requestCreatedAt: request.creationDate,
        ));

    await refresh();
  }

  /// Demo-only resolution: append a history entry and remove the request from
  /// the in-memory pending list. No crypto, no API, no persistence.
  void _demoResolve(AuthRequest request, {required bool approved}) {
    ref.read(historyProvider.notifier).add(HistoryEntry(
          requestId: request.id,
          deviceType: request.requestDeviceType,
          ipAddress: request.requestIpAddress,
          fingerprint: request.fingerprint,
          approved: approved,
          respondedAt: DateTime.now(),
          requestCreatedAt: request.creationDate,
        ));
    final remaining = [...?state.value]..removeWhere((r) => r.id == request.id);
    state = AsyncData(remaining);
  }
}

// ── History ──

class HistoryEntry {
  final String requestId;
  final String deviceType;
  final String ipAddress;
  final String? fingerprint;
  final bool approved;
  final DateTime respondedAt;
  final DateTime requestCreatedAt;

  const HistoryEntry({
    required this.requestId,
    required this.deviceType,
    required this.ipAddress,
    this.fingerprint,
    required this.approved,
    required this.respondedAt,
    required this.requestCreatedAt,
  });

  /// How long between request creation and our response.
  Duration get responseTime => respondedAt.difference(requestCreatedAt);

  Map<String, dynamic> toJson() => {
        'requestId': requestId,
        'deviceType': deviceType,
        'ipAddress': ipAddress,
        'fingerprint': fingerprint,
        'approved': approved,
        'respondedAt': respondedAt.toIso8601String(),
        'requestCreatedAt': requestCreatedAt.toIso8601String(),
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        requestId: json['requestId'] as String? ?? '',
        deviceType: json['deviceType'] as String,
        ipAddress: json['ipAddress'] as String,
        fingerprint: json['fingerprint'] as String?,
        approved: json['approved'] as bool,
        respondedAt: DateTime.parse(
            json['respondedAt'] as String? ?? json['timestamp'] as String),
        requestCreatedAt: DateTime.parse(
            json['requestCreatedAt'] as String? ??
                json['respondedAt'] as String? ??
                json['timestamp'] as String),
      );
}

class HistoryNotifier extends StateNotifier<List<HistoryEntry>> {
  static const _key = 'auth_request_history';
  static const _maxEntries = 50;
  final FlutterSecureStorage _storage =
      const FlutterSecureStorage();

  HistoryNotifier() : super([]) {
    if (demoActive) {
      state = demoHistoryEntries();
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    final raw = await _storage.read(key: _key);
    if (raw != null) {
      final list = (jsonDecode(raw) as List)
          .map((e) => HistoryEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      // Auto-cleanup entries older than 30 days
      final cutoff = DateTime.now().subtract(const Duration(days: 30));
      final filtered = list.where((e) => e.respondedAt.isAfter(cutoff)).toList();
      state = filtered;
      if (filtered.length != list.length) {
        await _save();
      }
    }
  }

  Future<void> add(HistoryEntry entry) async {
    state = [entry, ...state].take(_maxEntries).toList();
    await _save();
  }

  Future<void> _save() async {
    if (demoActive) return; // demo history is in-memory only
    await _storage.write(
      key: _key,
      value: jsonEncode(state.map((e) => e.toJson()).toList()),
    );
  }

  Future<void> removeAt(int index) async {
    state = [...state]..removeAt(index);
    await _save();
  }

  Future<void> clear() async {
    state = [];
    if (demoActive) return;
    await _storage.delete(key: _key);
  }
}
