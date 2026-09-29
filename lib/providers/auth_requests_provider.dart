import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../demo_fixtures.dart';
import '../models/auth_request.dart';
import '../models/hub_event.dart';
import '../models/server_environment.dart';
import '../models/settings_snapshot.dart';
import '../models/user_session.dart';
import '../services/secure_storage_service.dart';
import '../services/vault_api.dart';
import '../utils/error_formatter.dart';
import 'service_providers.dart';
import 'session_provider.dart';

final authRequestsProvider =
    AsyncNotifierProvider<AuthRequestsNotifier, List<AuthRequest>>(
  AuthRequestsNotifier.new,
);

/// The local clock used for the 5-minute window checks (tests override it
/// with fake time; the server clock offset is applied by [AuthRequest]).
final requestClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

/// Local history of approved/denied requests of the signed-in account
/// (F13): kept in the app's secure store under a server + email key,
/// rebuilt when the account changes and deleted on logout. Signed out it is
/// an empty in-memory list; in the screenshot demo it holds the fixtures
/// (the runtime demo overrides it in its own container). Never persisted in
/// any demo.
final historyProvider =
    StateNotifierProvider<HistoryNotifier, List<HistoryEntry>>((ref) {
  final account = ref.watch(sessionProvider.select(_historyAccount));
  if (isDemoMode) return HistoryNotifier.inMemory(demoHistoryEntries());
  if (demoActive || account == null) return HistoryNotifier.inMemory();
  return HistoryNotifier(
    storage: ref.read(secureStorageProvider),
    serverUrl: account.serverUrl,
    email: account.email,
  );
});

({String serverUrl, String email})? _historyAccount(
  AsyncValue<UserSession?> session,
) {
  final s = session.valueOrNull;
  if (s == null) return null;
  return (serverUrl: s.serverUrl, email: s.email.trim().toLowerCase());
}

/// Trust of [ip] from local history: true = the latest answer for that IP
/// was approve, false = deny, null = unknown. A blank IP never matches
/// anything (R5) — a request without an IP gets no trust colour. Neither
/// does a non-public address ([isNonPublicIp]): behind a reverse proxy that
/// does not forward the client IP, a Docker/NAT gateway or on a LAN it
/// names the hop, not the device, so one approval would colour every later
/// request — an attacker's included — as known.
bool? ipTrustStatus(String ip, List<HistoryEntry> history) {
  final needle = ip.trim().toLowerCase();
  if (needle.isEmpty || isNonPublicIp(needle)) return null;
  for (final entry in history) {
    if (entry.ipAddress.trim().toLowerCase() == needle) return entry.approved;
  }
  return null;
}

/// Loopback, private (RFC 1918), CGNAT (100.64/10), link-local, unspecified
/// and IPv6 unique-local addresses (also IPv4-mapped). Not an IP → false.
bool isNonPublicIp(String ip) {
  final address = InternetAddress.tryParse(ip.trim());
  if (address == null) return false;
  var bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv6) {
    final mapped = bytes.length == 16 &&
        bytes.sublist(0, 10).every((b) => b == 0) &&
        bytes[10] == 0xff &&
        bytes[11] == 0xff;
    if (mapped) {
      bytes = bytes.sublist(12);
    } else {
      if (address.isLoopback || address.isLinkLocal) return true;
      if (bytes.every((b) => b == 0)) return true; // ::
      return (bytes[0] & 0xfe) == 0xfc; // fc00::/7
    }
  }
  final a = bytes[0], b = bytes[1];
  return a == 0 ||
      a == 10 ||
      a == 127 ||
      (a == 100 && b >= 64 && b <= 127) ||
      (a == 169 && b == 254) ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168);
}

/// Approve was refused locally: the request left its 5-minute window
/// (server clock) before it was answered (F5). The card is dropped.
class AuthRequestExpiredException implements Exception {
  const AuthRequestExpiredException();
  @override
  String toString() => 'AuthRequestExpiredException';
}

/// Approve was refused locally: no fingerprint phrase could be computed for
/// the request's public key, so the user cannot verify it (A1).
class FingerprintUnavailableException implements Exception {
  const FingerprintUnavailableException();
  @override
  String toString() => 'FingerprintUnavailableException';
}

/// Pending "Login with device" requests of the signed-in account.
///
/// Lifecycle: [build] follows the signed-in account (not token refreshes):
/// it subscribes to the hub, connects it once, starts polling and fetches.
/// [pause]/[resume] follow the RequestsScreen and app lifecycle; [stop] is
/// called on logout and the demo toggles. Every result is tagged with an
/// epoch so a late response of an old account/session is dropped (F7).
/// Demo never reaches the API, the hub or a timer.
class AuthRequestsNotifier extends AsyncNotifier<List<AuthRequest>> {
  /// Refresh burst after [resume] (R1): stops at the first success.
  @visibleForTesting
  static const burstAttempts = 10;
  @visibleForTesting
  static const burstDelay = Duration(seconds: 2);
  static const _burstMaxConsecutiveErrors = 3;

  Timer? _pollTimer;
  Timer? _expiryTimer;
  Timer? _burstTimer;
  StreamSubscription<HubEvent>? _hubSub;
  UserSession? _session;
  int _epoch = 0;
  int _burst = 0;
  bool _hubStarted = false;
  bool _paused = false;

  @override
  Future<List<AuthRequest>> build() async {
    final account = ref.watch(sessionProvider.select(sessionAccountKey));
    _teardown();
    ref.onDispose(_teardown);

    // Demo: serve the fixture list, no polling, no WebSocket, no API. (The
    // runtime demo runs its own notifier in its own container; the real
    // container stays empty meanwhile.)
    if (isDemoMode) return demoPendingRequests();
    if (demoActive) return const [];

    final session = ref.read(sessionProvider).valueOrNull;
    if (account == null || session == null) return const [];
    _session = session;

    // A11: a new poll interval applies right away.
    ref.listen<int>(pollIntervalProvider, (_, __) {
      if (_pollTimer != null) _startPollTimer();
    });
    // F5: hide requests the moment they leave the 5-minute window.
    listenSelf((_, next) => _scheduleExpirySweep(next.valueOrNull));

    _startHub(session);
    _startPollTimer();
    final epoch = _epoch;
    try {
      return await _fetchRequests();
    } catch (e) {
      if (epoch == _epoch && isSessionEndedError(e)) _handOverSessionEnd();
      rethrow;
    }
  }

  /// Stops polling, the expiry sweep, a running refresh burst and the hub
  /// subscription. The hub itself is reset by the session layer.
  void stop() => _teardown();

  void _teardown() {
    _epoch++;
    _cancelBurst();
    _pollTimer?.cancel();
    _pollTimer = null;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _hubSub?.cancel();
    _hubSub = null;
    _hubStarted = false;
    _paused = false;
    _session = null;
  }

  bool get _live => !demoActive && _session != null;

  DateTime _now() => ref.read(requestClockProvider)();

  void _cancelBurst() {
    _burst++;
    _burstTimer?.cancel();
    _burstTimer = null;
  }

  /// The pause between burst attempts; cancelled (never completes) by
  /// [_cancelBurst], so no timer outlives a pause or logout.
  Future<void> _burstPause() {
    final done = Completer<void>();
    _burstTimer?.cancel();
    _burstTimer = Timer(burstDelay, done.complete);
    return done.future;
  }

  Future<List<AuthRequest>> _fetchRequests() async {
    // F7: demo never reaches the API.
    if (demoActive) return state.valueOrNull ?? const [];
    if (_session == null) return const [];
    // The API fills the fingerprint per request (null for a malformed key)
    // and drops answered/expired requests (A1, F5, F8).
    return ref.read(apiServiceProvider).getPendingRequests();
  }

  void _startHub(UserSession session) {
    final ServerEnvironment env;
    try {
      env = session.environment;
    } on FormatException {
      return; // unusable server URL: polling still reports the error
    }
    final hub = ref.read(notificationServiceProvider);
    _hubSub = hub.events.listen(_onHubEvent);
    _hubStarted = true;
    // The only connect per build (F10): resume() reconnects only after a
    // pause(). Tokens come from the API via the hub's token provider.
    unawaited(hub.connectEnvironment(env).catchError((Object _) {}));
  }

  void _onHubEvent(HubEvent event) {
    // 15 = new request, 16 = answered elsewhere (A10). 11 (LogOut) is
    // handled by the session layer.
    if (event.isAuthRequest || event.isAuthRequestResponse) {
      _silentRefresh();
    }
  }

  void _startPollTimer() {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!_live) return; // F7
    final seconds = sanitizePollInterval(ref.read(pollIntervalProvider));
    _pollTimer = Timer.periodic(
      Duration(seconds: seconds),
      (_) => _silentRefresh(),
    );
  }

  void _scheduleExpirySweep(List<AuthRequest>? requests) {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (!_live || requests == null || requests.isEmpty) return;
    final now = _now();
    var next = requests.first.remaining(now);
    for (final r in requests.skip(1)) {
      final left = r.remaining(now);
      if (left < next) next = left;
    }
    _expiryTimer = Timer(
      next + const Duration(milliseconds: 250),
      _sweepExpired,
    );
  }

  void _sweepExpired() {
    _expiryTimer = null;
    final requests = state.valueOrNull;
    if (!_live || requests == null) return;
    final now = _now();
    final actionable = requests.where((r) => r.isActionableAt(now)).toList();
    if (actionable.length != requests.length) {
      state = AsyncData(actionable); // listenSelf reschedules
    } else {
      _scheduleExpirySweep(requests);
    }
  }

  /// App/screen goes to background (or the screen is disposed): stop
  /// polling, a running refresh burst and the WebSocket.
  void pause() {
    _cancelBurst();
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!_live) return;
    _paused = true;
    if (_hubStarted) ref.read(notificationServiceProvider).pause();
  }

  /// App/screen returns: reconnect after a [pause], restart polling and run
  /// a refresh burst (stops at the first success; a newer resume/pause
  /// cancels it). Skipped while the first fetch of [build] is running.
  void resume() {
    if (!_live) return;
    if (_paused) {
      _paused = false;
      ref.read(notificationServiceProvider).resume();
    }
    _startPollTimer();
    if (!state.isLoading) _aggressiveRefresh();
  }

  /// Fast pickup after resume (R1): retries a failed fetch up to
  /// [burstAttempts] times, [burstDelay] apart; the first success ends it.
  /// Three network errors in a row, or any server error, are shown.
  Future<void> _aggressiveRefresh() async {
    final burst = ++_burst;
    final epoch = _epoch;
    var consecutiveErrors = 0;
    bool current() => burst == _burst && epoch == _epoch && _live;

    for (var attempt = 1; attempt <= burstAttempts; attempt++) {
      if (!current()) return;
      try {
        final requests = await _fetchRequests();
        if (!current()) return;
        state = AsyncData(requests);
        return;
      } catch (e, st) {
        if (!current()) return;
        if (isSessionEndedError(e)) {
          _onSessionEnded(e, st);
          return;
        }
        // The server answered: retrying won't change that. A connection
        // closed during TLS set-up is only *maybe* an mTLS rejection (a
        // stale connection after resume looks the same): retry it.
        final heuristic =
            e is ClientCertificateRequiredException && !e.definitive;
        if (e is ApiException && !heuristic) {
          state = AsyncError(e, st);
          if (isAuthError(e)) _stopPollingOnAuthError();
          return;
        }
        consecutiveErrors++;
        if (consecutiveErrors >= _burstMaxConsecutiveErrors) {
          state = AsyncError(e, st);
          return;
        }
      }
      await _burstPause();
    }
  }

  /// Background poll — silently ignores transient network errors.
  /// Sets error state only for auth failures.
  Future<void> _silentRefresh() async {
    if (!_live) return;
    final epoch = _epoch;
    try {
      final requests = await _fetchRequests();
      if (epoch != _epoch) return;
      state = AsyncData(requests);
    } catch (e, st) {
      if (epoch != _epoch) return;
      if (isSessionEndedError(e)) {
        _onSessionEnded(e, st);
      } else if (isAuthError(e)) {
        state = AsyncError(e, st);
        _stopPollingOnAuthError();
      }
      // Other errors (network, 5xx) — keep the current list silently.
    }
  }

  /// F11: a 401 that survived a successful token refresh (e.g. a proxy that
  /// strips `Authorization`). Polling on would refresh the token on every
  /// tick and run into the identity rate limit (bitwarden.com: 10/min per
  /// IP), so stop the timer and any burst — the session stays. A manual
  /// refresh or the next resume starts polling again.
  void _stopPollingOnAuthError() {
    _cancelBurst();
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// F11: the session is dead — stop polling and hand over to the session
  /// layer (forced re-login, device_id kept).
  void _onSessionEnded(Object error, StackTrace st) {
    state = AsyncError(error, st);
    _handOverSessionEnd();
  }

  void _handOverSessionEnd() {
    _cancelBurst();
    _pollTimer?.cancel();
    _pollTimer = null;
    // Also reached via VaultApiService.onSessionEnded; endSession is
    // idempotent.
    unawaited(ref
        .read(sessionProvider.notifier)
        .endSession(SessionEndNotice.sessionEnded));
  }

  /// Manual refresh — shows error if it fails.
  Future<void> refresh() async {
    if (demoActive) {
      // Fixtures are static; keep their countdown fresh.
      final requests = state.valueOrNull;
      if (requests != null) {
        state = AsyncData(requests.map(demoRestamp).toList());
      }
      return;
    }
    if (_session == null) return;
    final epoch = _epoch;
    final next = await AsyncValue.guard(_fetchRequests);
    if (epoch != _epoch) return;
    final error = next.error;
    if (error != null && isSessionEndedError(error)) {
      _onSessionEnded(error, next.stackTrace ?? StackTrace.current);
      return;
    }
    state = next;
    if (error == null) {
      // Polling may have stopped on an auth error: the session works again.
      if (_pollTimer == null && !_paused) _startPollTimer();
    } else if (isAuthError(error)) {
      _stopPollingOnAuthError();
    }
  }

  Future<void> approve(AuthRequest request) async {
    // Demo: no crypto/API — record it in history and drop it from pending.
    if (demoActive) {
      _demoResolve(request, approved: true);
      return;
    }
    // F5: never approve outside the window the server honours.
    if (!request.isActionableAt(_now())) {
      _drop(request.id);
      throw const AuthRequestExpiredException();
    }
    // A1: no phrase, no way to verify — never approve.
    if (request.fingerprint == null) {
      throw const FingerprintUnavailableException();
    }
    final api = ref.read(apiServiceProvider);
    final crypto = ref.read(cryptoServiceProvider);
    final storage = ref.read(secureStorageProvider);
    final userKey = ref.read(userKeyProvider);

    if (userKey == null) throw StateError('Vault is locked');
    final epoch = _epoch;

    final encryptedKey =
        crypto.encryptUserKeyForApproval(userKey, request.publicKey);
    final deviceId = await storage.getOrCreateDeviceId();

    await _respond(() => api.respondToAuthRequest(
          requestId: request.id,
          approved: true,
          encryptedKey: encryptedKey,
          deviceId: deviceId,
        ));
    if (epoch != _epoch) return;

    _recordHistory(request, approved: true);
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
    final epoch = _epoch;
    final deviceId = await storage.getOrCreateDeviceId();

    await _respond(() => api.respondToAuthRequest(
          requestId: request.id,
          approved: false,
          deviceId: deviceId,
        ));
    if (epoch != _epoch) return;

    _recordHistory(request, approved: false);
    await refresh();
  }

  /// Runs the PUT; a request that is gone, answered or superseded on the
  /// server is refreshed away before the error is shown.
  Future<void> _respond(Future<void> Function() put) async {
    try {
      await put();
    } on AuthRequestAlreadyAnsweredException {
      unawaited(refresh());
      rethrow;
    } on AuthRequestNotFoundException {
      unawaited(refresh());
      rethrow;
    } on AuthRequestSupersededException {
      unawaited(refresh());
      rethrow;
    } on SessionEndedException catch (e, st) {
      _onSessionEnded(e, st);
      rethrow;
    }
  }

  void _drop(String id) {
    final requests = state.valueOrNull;
    if (requests == null) return;
    state = AsyncData([...requests]..removeWhere((r) => r.id == id));
  }

  void _recordHistory(AuthRequest request, {required bool approved}) {
    ref.read(historyProvider.notifier).add(HistoryEntry(
          requestId: request.id,
          deviceType: request.requestDeviceType,
          ipAddress: request.requestIpAddress,
          fingerprint: request.fingerprint,
          approved: approved,
          respondedAt: DateTime.now(),
          requestCreatedAt: request.creationDate,
        ));
  }

  /// Demo-only: the '+' action injects a fresh incoming request on top of the
  /// pending list so testers can see the arrival + trust-frame behaviour.
  void addDemoRequest() {
    if (!demoActive) return;
    state = AsyncData([demoRandomPending(), ...?state.value]);
  }

  /// Demo-only resolution: append a history entry and remove the request from
  /// the in-memory pending list. No crypto, no API, no persistence.
  void _demoResolve(AuthRequest request, {required bool approved}) {
    _recordHistory(request, approved: approved);
    _drop(request.id);
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
        requestCreatedAt: DateTime.parse(json['requestCreatedAt'] as String? ??
            json['respondedAt'] as String? ??
            json['timestamp'] as String),
      );
}

/// Approve/deny history of one account.
///
/// Persistent instances read/write [SecureStorageService.loadHistory] /
/// [SecureStorageService.saveHistory] (same keychain options as every other
/// secret, key = server + email, removed by `clearSessionData`). In-memory
/// instances (signed out, demo) never touch storage.
class HistoryNotifier extends StateNotifier<List<HistoryEntry>> {
  HistoryNotifier({
    required SecureStorageService storage,
    required String serverUrl,
    required String email,
  })  : _storage = storage,
        _serverUrl = serverUrl,
        _email = email,
        super(const []) {
    loaded = _load();
  }

  /// Never persisted (signed out, demo).
  HistoryNotifier.inMemory([super.state = const []])
      : _storage = null,
        _serverUrl = null,
        _email = null {
    loaded = Future<void>.value();
  }

  static const maxEntries = 50;
  static const retention = Duration(days: 30);

  final SecureStorageService? _storage;
  final String? _serverUrl;
  final String? _email;

  /// Completes when the stored history has been read.
  late final Future<void> loaded;

  bool get isPersistent => _storage != null;

  Future<void> _load() async {
    final storage = _storage;
    if (storage == null) return;
    final List<HistoryEntry> stored;
    var migrated = false;
    try {
      var raw =
          await storage.loadHistory(serverUrl: _serverUrl!, email: _email!);
      if (raw == null) {
        // One-time migration of the unscoped history of older builds. A new
        // sign-in deletes that item (SessionNotifier.setup), so whatever is
        // left was written while this very session was signed in.
        raw = await storage.readLegacyHistory();
        migrated = raw != null;
      }
      stored = raw == null ? const [] : _decode(raw);
    } catch (_) {
      return; // unreadable history = empty
    }
    if (!mounted) return;
    final cutoff = DateTime.now().subtract(retention);
    final kept = stored.where((e) => e.respondedAt.isAfter(cutoff)).toList();
    // Entries recorded while loading stay on top.
    final added = state;
    final addedIds = added.map((e) => e.requestId).toSet();
    state = [
      ...added,
      ...kept.where((e) => !addedIds.contains(e.requestId)),
    ].take(maxEntries).toList();
    if (migrated) {
      if (await _save()) await storage.deleteLegacyHistory();
    } else if (added.isNotEmpty || kept.length != stored.length) {
      await _save();
    }
  }

  static List<HistoryEntry> _decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final result = <HistoryEntry>[];
    for (final item in decoded) {
      try {
        result
            .add(HistoryEntry.fromJson(Map<String, dynamic>.from(item as Map)));
      } catch (_) {
        // skip a malformed entry
      }
    }
    return result;
  }

  Future<void> add(HistoryEntry entry) async {
    if (!mounted) return;
    state = [entry, ...state].take(maxEntries).toList();
    await _save();
  }

  /// Persists the list; false when it could not be written.
  Future<bool> _save() async {
    final storage = _storage;
    if (storage == null || !mounted) return false;
    try {
      await storage.saveHistory(
        serverUrl: _serverUrl!,
        email: _email!,
        json: jsonEncode(state.map((e) => e.toJson()).toList()),
      );
      return true;
    } catch (_) {
      // Keychain unavailable: the in-memory list still works.
      return false;
    }
  }

  Future<void> removeAt(int index) async {
    if (!mounted || index < 0 || index >= state.length) return;
    state = [...state]..removeAt(index);
    await _save();
  }

  Future<void> clear() async {
    if (!mounted) return;
    state = [];
    final storage = _storage;
    if (storage == null) return;
    try {
      await storage.deleteHistory(serverUrl: _serverUrl!, email: _email!);
    } catch (_) {
      // best effort
    }
  }
}
