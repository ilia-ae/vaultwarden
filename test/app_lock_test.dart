// R6: when the app locks, every route above home (dialogs, sheets) closes —
// but only for a real signed-in session, never in demo mode, never on the
// setup screen and never while a system file picker is open. Logout resets
// the lock flag.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_approver/app.dart';
import 'package:vault_approver/demo_runtime.dart';
import 'package:vault_approver/models/auth_request.dart';
import 'package:vault_approver/models/user_session.dart';
import 'package:vault_approver/providers/auth_requests_provider.dart';
import 'package:vault_approver/providers/service_providers.dart';
import 'package:vault_approver/providers/session_provider.dart';
import 'package:vault_approver/screens/requests_screen.dart';
import 'package:vault_approver/screens/setup_screen.dart';
import 'package:vault_approver/services/biometric_service.dart';
import 'package:vault_approver/services/secure_storage_service.dart';
import 'package:vault_approver/services/settings_service.dart';
import 'package:vault_approver/utils/external_picker.dart';
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

  UserSession? session;

  @override
  Future<UserSession?> loadSession() async => session;

  @override
  Future<void> clearAll() async => session = null;
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

const _dialogText = 'probe dialog';

Future<ProviderContainer> _pumpApp(
  WidgetTester tester, {
  required UserSession? session,
}) async {
  final settings = SettingsService(await SharedPreferences.getInstance());
  await tester.pumpWidget(ProviderScope(
    overrides: [
      settingsServiceProvider.overrideWithValue(settings),
      secureStorageProvider.overrideWithValue(_FakeStorage(session)),
      biometricServiceProvider.overrideWithValue(_NoBiometrics()),
      authRequestsProvider.overrideWith(_NoNetworkRequests.new),
    ],
    child: const App(),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
}

Future<void> _unlock(WidgetTester tester, ProviderContainer container) async {
  container.read(isLockedProvider.notifier).state = false;
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
}

void _openDialog(WidgetTester tester, Type over) {
  showDialog<void>(
    context: tester.element(find.byType(over)),
    builder: (_) => const AlertDialog(content: Text(_dialogText)),
  );
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
  });

  setUp(() {
    // HistoryNotifier reads its list from secure storage.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => null,
    );
  });

  testWidgets('signed in: lock closes dialogs above home', (tester) async {
    resetLifecycleOnTearDown(tester);
    mockPrivacyChannel(tester);
    final container = await _pumpApp(tester, session: _session);
    await _unlock(tester, container);
    expect(find.byType(RequestsScreen), findsOneWidget);

    _openDialog(tester, RequestsScreen);
    await tester.pumpAndSettle();
    expect(find.text(_dialogText), findsOneWidget);

    final dialogRoute = ModalRoute.of(tester.element(find.text(_dialogText)))!;
    setLifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    expect(container.read(isLockedProvider), isTrue);
    // Popped at once; no frames run while paused, so its exit animation
    // finishes after resume.
    expect(dialogRoute.isActive, isFalse);
    setLifecycle(tester, AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text(_dialogText), findsNothing);
    expect(find.byType(LockSkeleton), findsOneWidget);
  });

  testWidgets('setup screen: dialogs are NOT closed on lock', (tester) async {
    resetLifecycleOnTearDown(tester);
    final container = await _pumpApp(tester, session: null);
    expect(find.byType(SetupScreen), findsOneWidget);

    _openDialog(tester, SetupScreen);
    await tester.pumpAndSettle();
    // A trip to the authenticator app for the 2FA code.
    setLifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    setLifecycle(tester, AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text(_dialogText), findsOneWidget);

    // Even with a stale "unlocked" flag that flips to locked.
    container.read(isLockedProvider.notifier).state = false;
    await tester.pump();
    setLifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    expect(container.read(isLockedProvider), isTrue);
    await tester.pumpAndSettle();
    expect(find.text(_dialogText), findsOneWidget);
  });

  testWidgets('no lock and no route closing while a file picker is open',
      (tester) async {
    resetLifecycleOnTearDown(tester);
    mockPrivacyChannel(tester);
    final container = await _pumpApp(tester, session: _session);
    await _unlock(tester, container);
    _openDialog(tester, RequestsScreen);
    await tester.pumpAndSettle();

    await runExternalPicker(() async {
      expect(externalPickerActive, isTrue);
      setLifecycle(tester, AppLifecycleState.paused);
      await tester.pump();
      setLifecycle(tester, AppLifecycleState.resumed);
      await tester.pump();
    });
    expect(externalPickerActive, isFalse);
    expect(container.read(isLockedProvider), isFalse);
    await tester.pumpAndSettle();
    expect(find.text(_dialogText), findsOneWidget);
  });

  testWidgets('demo mode never closes routes', (tester) async {
    resetLifecycleOnTearDown(tester);
    mockPrivacyChannel(tester);
    demoRuntime.value = true;
    addTearDown(() => demoRuntime.value = false);
    final container = await _pumpApp(tester, session: null);
    await _unlock(tester, container);
    expect(find.byType(RequestsScreen), findsOneWidget);
    _openDialog(tester, RequestsScreen);
    await tester.pumpAndSettle();

    setLifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    // Even if something locks in demo, the guard keeps the routes.
    container.read(isLockedProvider.notifier).state = true;
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text(_dialogText), findsOneWidget);
  });

  testWidgets('logout resets the lock flag', (tester) async {
    resetLifecycleOnTearDown(tester);
    mockPrivacyChannel(tester);
    final container = await _pumpApp(tester, session: _session);
    await _unlock(tester, container);
    expect(container.read(isLockedProvider), isFalse);

    await container.read(sessionProvider.notifier).logout();
    await tester.pumpAndSettle();
    expect(container.read(isLockedProvider), isTrue);
    expect(find.byType(SetupScreen), findsOneWidget);
  });
}
