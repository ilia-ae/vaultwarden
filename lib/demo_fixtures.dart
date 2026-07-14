// Demo-mode fixture data for App Store screenshot capture.
//
// Activated via build-time flag:
//   flutter build ios --simulator --dart-define=DEMO_MODE=<mode>
//
// Modes:
//   off    — production behavior (default)
//   main   — logged in + unlocked + 1 pending request + 5 history entries
//   lock   — logged in but locked (Face ID prompt visible)
//   setup  — not logged in (SetupScreen visible)
//   totp   — not logged in, TOTP dialog auto-shown over SetupScreen
//
// Capture pipeline drives this from screenshots-capture, then runs Maestro
// flows that take simctl screenshots of each state.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'demo_runtime.dart';
import 'models/auth_request.dart';
import 'models/user_session.dart';
import 'providers/auth_requests_provider.dart';
import 'providers/session_provider.dart';

// Re-export the demo flags so the many `import 'demo_fixtures.dart'` sites keep
// seeing demoMode/isDemoMode/demoActive/demoRuntime unchanged.
export 'demo_runtime.dart';

/// Provider overrides for the current demo mode.
/// Returns empty list when DEMO_MODE=off, so production builds are unaffected.
List<Override> demoModeOverrides() {
  switch (demoMode) {
    case 'main':
      return _mainOverrides();
    case 'lock':
      return _lockOverrides();
    case 'setup':
    case 'totp':
      return _setupOverrides();
    default:
      return const [];
  }
}

UserSession demoSession() => UserSession(
      email: 'demo@vaultapprover.app',
      serverUrl: 'https://vault.example.com',
      accessToken: 'demo-access-token',
      refreshToken: 'demo-refresh-token',
      accessTokenExpiry: DateTime.now().add(const Duration(hours: 1)),
    );

List<AuthRequest> demoPendingRequests() {
  final now = DateTime.now();
  return [
    AuthRequest(
      id: 'demo-pending-1',
      publicKey: 'demo-public-key',
      requestDeviceType: 'macOS Browser',
      requestIpAddress: '192.168.1.42',
      creationDate: now.subtract(const Duration(minutes: 1)),
      fingerprint: 'ocean-mountain-river-cloud-fox',
    ),
  ];
}

List<HistoryEntry> demoHistoryEntries() {
  final now = DateTime.now();
  return [
    HistoryEntry(
      requestId: 'demo-h-1',
      deviceType: 'iPhone iOS',
      ipAddress: '10.0.1.15',
      fingerprint: 'apple-sand-wave-tree-bird',
      approved: true,
      respondedAt: now.subtract(const Duration(minutes: 5)),
      requestCreatedAt:
          now.subtract(const Duration(minutes: 5, seconds: 2)),
    ),
    HistoryEntry(
      requestId: 'demo-h-2',
      deviceType: 'Linux Firefox',
      ipAddress: '203.0.113.42',
      fingerprint: 'forest-river-stone-deer-moon',
      approved: true,
      respondedAt: now.subtract(const Duration(hours: 2)),
      requestCreatedAt:
          now.subtract(const Duration(hours: 2, seconds: 3)),
    ),
    HistoryEntry(
      requestId: 'demo-h-3',
      deviceType: 'Windows Chrome',
      ipAddress: '198.51.100.18',
      fingerprint: 'cloud-mountain-fire-eagle-leaf',
      approved: false,
      respondedAt: now.subtract(const Duration(days: 1)),
      requestCreatedAt:
          now.subtract(const Duration(days: 1, seconds: 5)),
    ),
    HistoryEntry(
      requestId: 'demo-h-4',
      deviceType: 'iPad iOS',
      ipAddress: '10.0.1.22',
      fingerprint: 'wind-sun-cloud-river-stone',
      approved: true,
      respondedAt: now.subtract(const Duration(days: 2)),
      requestCreatedAt:
          now.subtract(const Duration(days: 2, seconds: 1)),
    ),
    HistoryEntry(
      requestId: 'demo-h-5',
      deviceType: 'macOS Safari',
      ipAddress: '192.168.1.50',
      fingerprint: 'mountain-fox-cloud-tree-bird',
      approved: true,
      respondedAt: now.subtract(const Duration(days: 3)),
      requestCreatedAt:
          now.subtract(const Duration(days: 3, seconds: 4)),
    ),
  ];
}

List<Override> _mainOverrides() => [
      sessionProvider
          .overrideWith(() => _DemoSessionNotifier(demoSession())),
      authRequestsProvider
          .overrideWith(() => _DemoAuthRequestsNotifier(demoPendingRequests())),
      historyProvider
          .overrideWith((ref) => _DemoHistoryNotifier(demoHistoryEntries())),
      isLockedProvider.overrideWith((ref) => false),
    ];

List<Override> _lockOverrides() => [
      sessionProvider
          .overrideWith(() => _DemoSessionNotifier(demoSession())),
      isLockedProvider.overrideWith((ref) => true),
    ];

List<Override> _setupOverrides() => [
      sessionProvider.overrideWith(() => _DemoSessionNotifier(null)),
      isLockedProvider.overrideWith((ref) => false),
    ];

class _DemoSessionNotifier extends SessionNotifier {
  _DemoSessionNotifier(this._fake);
  final UserSession? _fake;

  @override
  Future<UserSession?> build() async => _fake;
}

class _DemoAuthRequestsNotifier extends AuthRequestsNotifier {
  _DemoAuthRequestsNotifier(this._fake);
  final List<AuthRequest> _fake;

  @override
  Future<List<AuthRequest>> build() async => _fake;

  @override
  void pause() {}

  @override
  void resume() {}
}

class _DemoHistoryNotifier extends HistoryNotifier {
  _DemoHistoryNotifier(List<HistoryEntry> entries) : super() {
    // HistoryNotifier's constructor kicks off an async _load() from secure
    // storage. On a fresh simulator (after `simctl uninstall`) storage is
    // empty, so _load() leaves state untouched and our seed wins.
    state = entries;
  }

  @override
  Future<void> add(HistoryEntry e) async {}

  @override
  Future<void> removeAt(int i) async {}
}
