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
//
// The runtime tester demo (5 taps on the build version) runs the whole UI in
// its own ProviderContainer with [runtimeDemoOverrides] (see App), so demo
// and real state never share a provider (F7).
//
// Every demo IP comes from the RFC 5737 documentation ranges (192.0.2.0/24,
// 198.51.100.0/24, 203.0.113.0/24): demo history must never colour a real
// LAN or public address (F13).
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'demo_runtime.dart';
import 'models/auth_request.dart';
import 'models/user_session.dart';
import 'providers/auth_requests_provider.dart';
import 'providers/session_provider.dart';
import 'services/shift_vectors.dart';

// Re-export the demo flags so the many `import 'demo_fixtures.dart'` sites keep
// seeing demoMode/isDemoMode/demoActive/demoRuntime unchanged.
export 'demo_runtime.dart';

/// Overrides of the isolated runtime-demo container: fake session, fixture
/// requests and history (in memory only), unlocked, no user key. Everything
/// else (settings, services) is read from the parent container; the demo
/// notifiers never call the services.
List<Override> runtimeDemoOverrides() => [
      runtimeDemoScopeProvider.overrideWithValue(true),
      sessionProvider.overrideWith(() => _DemoSessionNotifier(demoSession())),
      authRequestsProvider
          .overrideWith(() => _DemoAuthRequestsNotifier(demoPendingRequests())),
      historyProvider.overrideWith(
          (ref) => HistoryNotifier.inMemory(demoHistoryEntries())),
      isLockedProvider.overrideWith((ref) => false),
      userKeyProvider.overrideWith((ref) => null),
      sessionEndNoticeProvider.overrideWith((ref) => null),
      ..._demoShiftVectorOverrides(),
    ];

/// PIN Shift in a demo: saved vectors live in memory for this demo only,
/// never in the device keychain, and the vault reader is not offered.
List<Override> _demoShiftVectorOverrides() => [
      shiftVectorStoreProvider
          .overrideWith((ref) => InMemoryShiftVectorStore()),
      shiftVectorSourceProvider.overrideWith((ref) => null),
    ];

/// Provider overrides for the current demo mode.
/// Returns empty list when DEMO_MODE=off, so production builds are unaffected.
List<Override> demoModeOverrides() {
  switch (demoMode) {
    case 'main':
      return [..._mainOverrides(), ..._demoShiftVectorOverrides()];
    case 'lock':
      return [..._lockOverrides(), ..._demoShiftVectorOverrides()];
    case 'setup':
    case 'totp':
      return [..._setupOverrides(), ..._demoShiftVectorOverrides()];
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
      requestIpAddress: '203.0.113.7', // new → grey frame
      creationDate: now.subtract(const Duration(minutes: 1)),
      fingerprint: 'ocean-mountain-river-cloud-fox',
    ),
  ];
}

/// Demo pull-to-refresh: a copy created a minute ago, so fixtures never run
/// out of their 5-minute window while a tester looks at them.
AuthRequest demoRestamp(AuthRequest r) => AuthRequest(
      id: r.id,
      publicKey: r.publicKey,
      requestDeviceType: r.requestDeviceType,
      requestIpAddress: r.requestIpAddress,
      creationDate: DateTime.now().subtract(const Duration(minutes: 1)),
      fingerprint: r.fingerprint,
    );

// ── Runtime demo: the '+' action synthesises fresh incoming requests ──

final _demoRng = Random();

/// Sample devices for the '+' button. Some IPs match [demoHistoryEntries] so
/// the injected cards show varied trust frames (green/red/grey).
const _demoSampleDevices = <(String, String)>[
  ('Chrome on Windows', '198.51.100.18'), // denied before → red frame
  ('Safari on macOS', '192.0.2.50'), // approved before → green frame
  ('Firefox on Linux', '203.0.113.42'), // approved before → green frame
  ('Brave on macOS', '192.0.2.15'), // approved before → green frame
  ('Safari on iPhone', '192.0.2.22'), // approved before → green frame
  ('Edge on Windows', '198.51.100.79'), // new → grey frame
  ('Chrome on Android', '203.0.113.4'), // new → grey frame
  ('Vivaldi on Linux', '198.51.100.9'), // new → grey frame
];

const _demoWords = [
  'ocean',
  'mountain',
  'river',
  'cloud',
  'fox',
  'ember',
  'willow',
  'harbor',
  'copper',
  'lantern',
  'meadow',
  'quartz',
  'raven',
  'saffron',
  'tundra',
  'violet',
  'walnut',
  'zephyr',
  'cedar',
  'marble',
];

String _demoFingerprint() {
  final words = [..._demoWords]..shuffle(_demoRng);
  return words.take(5).join('-');
}

/// A single fresh incoming request for the runtime-demo '+' button.
AuthRequest demoRandomPending() {
  final (device, ip) =
      _demoSampleDevices[_demoRng.nextInt(_demoSampleDevices.length)];
  final now = DateTime.now();
  return AuthRequest(
    id: 'demo-add-${now.microsecondsSinceEpoch}',
    publicKey: 'demo-public-key',
    requestDeviceType: device,
    requestIpAddress: ip,
    creationDate: now,
    fingerprint: _demoFingerprint(),
  );
}

List<HistoryEntry> demoHistoryEntries() {
  final now = DateTime.now();
  return [
    HistoryEntry(
      requestId: 'demo-h-1',
      deviceType: 'iPhone iOS',
      ipAddress: '192.0.2.15',
      fingerprint: 'apple-sand-wave-tree-bird',
      approved: true,
      respondedAt: now.subtract(const Duration(minutes: 5)),
      requestCreatedAt: now.subtract(const Duration(minutes: 5, seconds: 2)),
    ),
    HistoryEntry(
      requestId: 'demo-h-2',
      deviceType: 'Linux Firefox',
      ipAddress: '203.0.113.42',
      fingerprint: 'forest-river-stone-deer-moon',
      approved: true,
      respondedAt: now.subtract(const Duration(hours: 2)),
      requestCreatedAt: now.subtract(const Duration(hours: 2, seconds: 3)),
    ),
    HistoryEntry(
      requestId: 'demo-h-3',
      deviceType: 'Windows Chrome',
      ipAddress: '198.51.100.18',
      fingerprint: 'cloud-mountain-fire-eagle-leaf',
      approved: false,
      respondedAt: now.subtract(const Duration(days: 1)),
      requestCreatedAt: now.subtract(const Duration(days: 1, seconds: 5)),
    ),
    HistoryEntry(
      requestId: 'demo-h-4',
      deviceType: 'iPad iOS',
      ipAddress: '192.0.2.22',
      fingerprint: 'wind-sun-cloud-river-stone',
      approved: true,
      respondedAt: now.subtract(const Duration(days: 2)),
      requestCreatedAt: now.subtract(const Duration(days: 2, seconds: 1)),
    ),
    HistoryEntry(
      requestId: 'demo-h-5',
      deviceType: 'macOS Safari',
      ipAddress: '192.0.2.50',
      fingerprint: 'mountain-fox-cloud-tree-bird',
      approved: true,
      respondedAt: now.subtract(const Duration(days: 3)),
      requestCreatedAt: now.subtract(const Duration(days: 3, seconds: 4)),
    ),
  ];
}

List<Override> _mainOverrides() => [
      sessionProvider.overrideWith(() => _DemoSessionNotifier(demoSession())),
      authRequestsProvider
          .overrideWith(() => _DemoAuthRequestsNotifier(demoPendingRequests())),
      historyProvider
          .overrideWith((ref) => _DemoHistoryNotifier(demoHistoryEntries())),
      isLockedProvider.overrideWith((ref) => false),
    ];

List<Override> _lockOverrides() => [
      sessionProvider.overrideWith(() => _DemoSessionNotifier(demoSession())),
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

/// Screenshot history: fixed entries, in memory only, never changes.
class _DemoHistoryNotifier extends HistoryNotifier {
  _DemoHistoryNotifier(super.entries) : super.inMemory();

  @override
  Future<void> add(HistoryEntry e) async {}

  @override
  Future<void> removeAt(int i) async {}
}
