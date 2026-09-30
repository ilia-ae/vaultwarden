// The status bar follows the app's theme on every screen: dark icons and
// text on the light theme, light ones on the dark theme — on the setup
// screen (a transparent AppBar picked white icons on the light scene), the
// lock screen and the requests screen.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_approver/app.dart';
import 'package:vault_approver/glass.dart';
import 'package:vault_approver/models/auth_request.dart';
import 'package:vault_approver/models/user_session.dart';
import 'package:vault_approver/providers/auth_requests_provider.dart';
import 'package:vault_approver/providers/service_providers.dart';
import 'package:vault_approver/screens/requests_screen.dart';
import 'package:vault_approver/screens/setup_screen.dart';
import 'package:vault_approver/services/biometric_service.dart';
import 'package:vault_approver/services/secure_storage_service.dart';
import 'package:vault_approver/services/settings_service.dart';
import 'package:vault_approver/widgets/unlock_shell.dart';

import 'screens/pin/pin_harness.dart';

final _session = UserSession(
  email: 'user@example.com',
  serverUrl: 'https://vault.example.com',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessTokenExpiry: DateTime(2100),
);

class _FakeStorage extends SecureStorageService {
  _FakeStorage(this.session);

  final UserSession? session;

  @override
  Future<UserSession?> loadSession() async => session;
}

class _NoBiometrics extends BiometricService {
  @override
  Future<bool> isAvailable() async => false;
}

class _NoNetworkRequests extends AuthRequestsNotifier {
  @override
  Future<List<AuthRequest>> build() async => const [];

  @override
  void resume() {}

  @override
  void pause() {}
}

Future<ProviderContainer> _pumpApp(
  WidgetTester tester, {
  required UserSession? session,
  required ThemeMode theme,
}) async {
  final settings = SettingsService(await SharedPreferences.getInstance());
  await tester.pumpWidget(ProviderScope(
    overrides: [
      settingsServiceProvider.overrideWithValue(settings),
      secureStorageProvider.overrideWithValue(_FakeStorage(session)),
      biometricServiceProvider.overrideWithValue(_NoBiometrics()),
      authRequestsProvider.overrideWith(_NoNetworkRequests.new),
      themeModeProvider.overrideWith((ref) => theme),
    ],
    child: const App(),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
}

/// The style the framework last sent to the platform.
void _expectStatusBar(Brightness theme, String screen) {
  final style = SystemChrome.latestStyle;
  expect(style, isNotNull, reason: screen);
  final dark = theme == Brightness.dark;
  // Android: the icons' colour.
  expect(
      style!.statusBarIconBrightness, dark ? Brightness.light : Brightness.dark,
      reason: '$screen: icons');
  // iOS: the brightness of what is under the bar (light => dark text).
  expect(style.statusBarBrightness, dark ? Brightness.dark : Brightness.light,
      reason: '$screen: iOS text');
  expect(style.statusBarColor, const Color(0x00000000),
      reason: '$screen: the scene shows through');
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'Vault Approver',
      packageName: 'com.vaultapprover.app',
      version: '1.0.5',
      buildNumber: '35',
      buildSignature: '',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
  });

  test('systemOverlayStyleFor: dark icons on light, light icons on dark', () {
    final light = systemOverlayStyleFor(Brightness.light);
    expect(light.statusBarIconBrightness, Brightness.dark);
    expect(light.statusBarBrightness, Brightness.light);
    final dark = systemOverlayStyleFor(Brightness.dark);
    expect(dark.statusBarIconBrightness, Brightness.light);
    expect(dark.statusBarBrightness, Brightness.dark);
    // The status bar only: the navigation bar keeps its platform handling.
    for (final style in [light, dark]) {
      expect(style.systemNavigationBarColor, isNull);
      expect(style.systemNavigationBarIconBrightness, isNull);
    }
  });

  for (final (mode, brightness) in [
    (ThemeMode.light, Brightness.light),
    (ThemeMode.dark, Brightness.dark),
  ]) {
    testWidgets('setup screen: status bar for the ${brightness.name} theme',
        (tester) async {
      await _pumpApp(tester, session: null, theme: mode);
      expect(find.byType(SetupScreen), findsOneWidget);
      // The setup screen has a (transparent) AppBar: its style is the one
      // that reaches the platform.
      expect(find.byType(AppBar), findsOneWidget);
      _expectStatusBar(brightness, 'setup');
    });

    testWidgets(
        'lock and requests screens: status bar for the ${brightness.name} '
        'theme', (tester) async {
      resetLifecycleOnTearDown(tester);
      mockPrivacyChannel(tester);
      final container = await _pumpApp(tester, session: _session, theme: mode);
      expect(find.byType(LockSkeleton), findsOneWidget);
      _expectStatusBar(brightness, 'lock');

      container.read(isLockedProvider.notifier).state = false;
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(RequestsScreen), findsOneWidget);
      _expectStatusBar(brightness, 'requests');
    });
  }

  testWidgets('switching the theme flips the status bar', (tester) async {
    final container =
        await _pumpApp(tester, session: null, theme: ThemeMode.light);
    _expectStatusBar(Brightness.light, 'setup light');
    container.read(themeModeProvider.notifier).state = ThemeMode.dark;
    await tester.pumpAndSettle();
    _expectStatusBar(Brightness.dark, 'setup dark');
  });
}
