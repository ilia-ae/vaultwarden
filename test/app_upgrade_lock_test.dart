// lockKeyMissing on TestFlight 1.1.0 (regression): after an update from
// 1.0.5, locking and unlocking the app — background, device locked, back
// again — must never end on "The encryption key for this account is
// missing" nor lose the stored user key, and a cold start afterwards must
// neither wipe nor ask for a new sign-in.
//
// The keychain is the iOS one as flutter_secure_storage 9.2.4 shows it to
// Dart (FakeAppleKeychain): while protected data is unavailable, `read`
// answers null instead of an error and — with the item's attributes
// readable — a `write` deletes the item and then fails. A token refresh or
// a sign-out while the phone is locked must neither lose the session nor
// leave a half-cleared keychain.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_approver/app.dart';
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/models/auth_request.dart';
import 'package:vault_approver/models/user_session.dart';
import 'package:vault_approver/providers/auth_requests_provider.dart';
import 'package:vault_approver/providers/service_providers.dart';
import 'package:vault_approver/providers/session_provider.dart';
import 'package:vault_approver/screens/requests_screen.dart';
import 'package:vault_approver/screens/setup_screen.dart';
import 'package:vault_approver/services/biometric_service.dart';
import 'package:vault_approver/services/crypto_service.dart';
import 'package:vault_approver/services/privacy_service.dart';
import 'package:vault_approver/services/secure_storage_service.dart';
import 'package:vault_approver/services/settings_service.dart';

import 'providers/provider_fakes.dart';

class _FaceId extends Fake implements BiometricService {
  int prompts = 0;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> authenticate({
    String reason = 'Authenticate to access Vault Approver',
  }) async {
    prompts++;
    return true;
  }
}

class _NoNetworkRequests extends AuthRequestsNotifier {
  @override
  Future<List<AuthRequest>> build() async => const [];

  @override
  void resume() {}

  @override
  void pause() {}
}

final _keyMissingText =
    lookupAppLocalizations(const Locale('en')).lockKeyMissing;

/// Moves the lifecycle one legal step at a time, as the platform does.
void _setLifecycle(WidgetTester tester, AppLifecycleState target) {
  const order = [
    AppLifecycleState.resumed,
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ];
  var i = order.indexOf(tester.binding.lifecycleState ?? order.first);
  if (i < 0) i = 0;
  final j = order.indexOf(target);
  while (i != j) {
    i += i < j ? 1 : -1;
    tester.binding.handleAppLifecycleStateChanged(order[i]);
  }
}

void _mockPrivacyChannels(WidgetTester tester) {
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel(PrivacyService.channelName),
    (call) async => call.method == 'isScreenCaptured' ? false : true,
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel(PrivacyService.eventChannelName),
    (_) async => null,
  );
  addTearDown(() {
    messenger.setMockMethodCallHandler(
        const MethodChannel(PrivacyService.channelName), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel(PrivacyService.eventChannelName), null);
  });
}

/// One app start: main()'s reinstall check, then the App in a fresh
/// container (a new process) over the same keychain and preferences.
Future<(ProviderContainer, bool)> _start(
  WidgetTester tester, {
  required FakeAppleKeychain keychain,
  required SharedPreferences prefs,
  required BiometricService faceId,
  FakeVaultApi? api,
}) async {
  final storage = appleStorage(keychain);
  var wiped = false;
  try {
    wiped = await storage.wipeIfReinstalled(prefs);
  } catch (_) {
    // main() logs and carries on.
  }
  final container = ProviderContainer(overrides: [
    settingsServiceProvider.overrideWithValue(SettingsService(prefs)),
    secureStorageProvider.overrideWithValue(storage),
    apiServiceProvider.overrideWithValue(api ?? FakeVaultApi()),
    notificationServiceProvider.overrideWithValue(FakeHub()),
    cryptoServiceProvider
        .overrideWithValue(CryptoService(runKdfInIsolate: false)),
    biometricServiceProvider.overrideWithValue(faceId),
    authRequestsProvider.overrideWith(_NoNetworkRequests.new),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const App()),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
  return (container, wiped);
}

/// Background → device locked → back to the app. With [keychainLateOnReturn]
/// the first frame back (inactive, which mounts the lock screen) runs
/// before protected data is available again.
Future<void> _lockAndReturn(
  WidgetTester tester,
  ProviderContainer container,
  FakeAppleKeychain keychain, {
  required bool keychainLateOnReturn,
}) async {
  _setLifecycle(tester, AppLifecycleState.paused);
  await tester.pump();
  expect(container.read(isLockedProvider), isTrue);
  keychain.locked = true; // device locked
  if (!keychainLateOnReturn) keychain.locked = false;
  _setLifecycle(tester, AppLifecycleState.inactive);
  await tester.pump();
  await tester.pump();
  keychain.locked = false;
  _setLifecycle(tester, AppLifecycleState.resumed);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

/// The app is in the foreground (the test binding starts without a
/// lifecycle state) and is put back there after the test.
void _foreground(WidgetTester tester) {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  addTearDown(() => _setLifecycle(tester, AppLifecycleState.resumed));
}

void _expectUnlocked(WidgetTester tester, ProviderContainer container,
    {String reason = ''}) {
  expect(find.text(_keyMissingText), findsNothing, reason: reason);
  expect(container.read(isLockedProvider), isFalse, reason: reason);
  expect(container.read(userKeyProvider), Harness.userKey, reason: reason);
  expect(find.byType(RequestsScreen), findsOneWidget, reason: reason);
}

void main() {
  setUp(() {
    PackageInfo.setMockInitialValues(
      appName: 'Vault Approver',
      packageName: 'com.vaultapprover.app',
      version: '1.1.0',
      buildNumber: '36',
      buildSignature: '',
    );
  });

  for (final attributesReadable in [false, true]) {
    testWidgets(
        'update from 1.0.5, lock/unlock cycles, cold start: key kept '
        '(attributes ${attributesReadable ? '' : 'not '}readable while locked)',
        (tester) async {
      _foreground(tester);
      _mockPrivacyChannels(tester);
      final faceId = _FaceId();

      // The phone as 1.0.5 left it: signed in, no install marker anywhere.
      final keychain = FakeAppleKeychain()
        ..metadataReadableWhileLocked = attributesReadable;
      await seedAsBuild105(keychain, CryptoService(runKdfInIsolate: false));
      final stored105 = Map.of(keychain.items);
      SharedPreferences.setMockInitialValues({
        'settings.theme_mode': 'dark',
        'settings.lock_timeout': 0,
      });
      final prefs = await SharedPreferences.getInstance();

      // First start of the new build.
      var (app, wiped) = await _start(tester,
          keychain: keychain, prefs: prefs, faceId: faceId);
      expect(wiped, isFalse, reason: 'an update is not a reinstall');
      expect(faceId.prompts, 1);
      _expectUnlocked(tester, app, reason: 'first start');
      final marker = prefs.getString(SecureStorageService.prefsInstallMarker);
      expect(marker, isNotNull);

      var prompts = 1;
      for (final late in [false, true, true, false, true]) {
        await _lockAndReturn(tester, app, keychain, keychainLateOnReturn: late);
        prompts++;
        expect(faceId.prompts, prompts, reason: 'late keychain: $late');
        _expectUnlocked(tester, app, reason: 'cycle $prompts, late $late');
      }

      // Nothing was deleted or rewritten.
      for (final entry in stored105.entries) {
        if (entry.key == SecureStorageService.historyKeyPrefix) continue;
        expect(keychain.items[entry.key], entry.value, reason: entry.key);
      }
      expect(keychain.items[SecureStorageService.keyInstallMarker], marker);

      // iOS ended the process in the background; the user opens the app.
      await tester.pumpWidget(const SizedBox());
      (app, wiped) = await _start(tester,
          keychain: keychain, prefs: prefs, faceId: faceId);
      expect(wiped, isFalse);
      expect(find.byType(SetupScreen), findsNothing);
      expect(faceId.prompts, prompts + 1);
      _expectUnlocked(tester, app, reason: 'cold start');
      expect(prefs.getString(SecureStorageService.prefsInstallMarker), marker);
      expect(keychain.mutationsWhileLocked, 0);
    });
  }

  testWidgets('a start while the keychain is locked keeps the next start',
      (tester) async {
    _foreground(tester);
    _mockPrivacyChannels(tester);
    final faceId = _FaceId();
    final keychain = FakeAppleKeychain();
    await seedAsBuild105(keychain, CryptoService(runKdfInIsolate: false));
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    final (app, _) =
        await _start(tester, keychain: keychain, prefs: prefs, faceId: faceId);
    _expectUnlocked(tester, app);

    // A start that runs before protected data is available: the reinstall
    // check and the session read see a locked keychain.
    await tester.pumpWidget(const SizedBox());
    keychain.locked = true;
    final storage = appleStorage(keychain);
    try {
      await storage.wipeIfReinstalled(prefs);
    } catch (_) {}
    keychain.locked = false;

    // The next ordinary start: no wipe, still signed in.
    final (again, wiped) =
        await _start(tester, keychain: keychain, prefs: prefs, faceId: faceId);
    expect(wiped, isFalse);
    expect(find.byType(SetupScreen), findsNothing);
    _expectUnlocked(tester, again);
    expect(keychain.items[SecureStorageService.keyEncryptedUserKey], isNotNull);
  });

  // Write guard: 9.2.4 turns a keychain write while the phone is locked into
  // "delete the item, then fail" — a token refresh right after the app went
  // to the background silently lost the session.
  group('keychain writes while the phone is locked', () {
    late FakeAppleKeychain keychain;
    late SharedPreferences prefs;
    late _FaceId faceId;
    late FakeVaultApi api;

    UserSession? storedSession() {
      final raw = keychain.items[SecureStorageService.keySession];
      return raw == null
          ? null
          : UserSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    }

    Future<ProviderContainer> signedIn(WidgetTester tester) async {
      _foreground(tester);
      _mockPrivacyChannels(tester);
      faceId = _FaceId();
      api = FakeVaultApi();
      keychain = FakeAppleKeychain()..metadataReadableWhileLocked = true;
      await seedAsBuild105(keychain, CryptoService(runKdfInIsolate: false));
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      final (app, _) = await _start(tester,
          keychain: keychain, prefs: prefs, faceId: faceId, api: api);
      _expectUnlocked(tester, app);
      return app;
    }

    /// Home button, then the side button: background, device locked.
    Future<void> backgroundAndLock(WidgetTester tester) async {
      _setLifecycle(tester, AppLifecycleState.paused);
      await tester.pump();
      keychain.locked = true;
    }

    /// iOS ends the process: its widgets, timers and listeners are gone
    /// (frames back on without a resume, then the tree is dropped).
    Future<void> endProcess(WidgetTester tester) async {
      keychain.availabilityEvents = false; // nobody left to hear them
      _setLifecycle(tester, AppLifecycleState.inactive);
      await tester.pumpWidget(const SizedBox());
    }

    Future<void> unlockAndReturn(WidgetTester tester) async {
      keychain.locked = false;
      _setLifecycle(tester, AppLifecycleState.inactive);
      await tester.pump();
      _setLifecycle(tester, AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    }

    testWidgets('a token refresh while locked is kept and written on resume',
        (tester) async {
      final app = await signedIn(tester);
      await backgroundAndLock(tester);
      // No availability event: only the resume (and the next keychain
      // access) may flush.
      keychain.availabilityEvents = false;

      final refreshed = testSession(accessToken: 'at-2', refreshToken: 'rt-2');
      api.simulateRefresh(refreshed);
      await tester.pump();
      expect(keychain.mutationsWhileLocked, 0, reason: 'keychain untouched');
      expect(storedSession()!.refreshToken, 'rt-1', reason: 'old one intact');
      expect(app.read(sessionProvider).value!.refreshToken, 'rt-2',
          reason: 'the in-memory session is the authority meanwhile');
      expect(app.read(secureStorageProvider).hasPendingChanges, isTrue);

      await unlockAndReturn(tester);
      expect(storedSession()!.refreshToken, 'rt-2');
      expect(storedSession()!.accessToken, 'at-2');
      expect(app.read(secureStorageProvider).hasPendingChanges, isFalse);
      _expectUnlocked(tester, app);
      expect(keychain.mutationsWhileLocked, 0);
    });

    testWidgets('a cold start after a locked refresh is still signed in',
        (tester) async {
      await signedIn(tester);
      await backgroundAndLock(tester);
      api.simulateRefresh(
          testSession(accessToken: 'at-2', refreshToken: 'rt-2'));
      await tester.pump();

      // iOS ends the process before the phone is unlocked again: the owed
      // write is gone with it, the stored session must not be. Later the
      // user unlocks the phone and opens the app.
      await endProcess(tester);
      keychain.locked = false;
      _setLifecycle(tester, AppLifecycleState.resumed);
      final (app, wiped) = await _start(tester,
          keychain: keychain, prefs: prefs, faceId: faceId);
      expect(wiped, isFalse);
      expect(find.byType(SetupScreen), findsNothing);
      _expectUnlocked(tester, app);
      expect(storedSession()!.refreshToken, 'rt-1');
      expect(
          keychain.items[SecureStorageService.keyEncryptedUserKey], isNotNull);
      expect(keychain.mutationsWhileLocked, 0);
    });

    testWidgets('a logout while locked clears the keychain once unlocked',
        (tester) async {
      final app = await signedIn(tester);
      final marker = prefs.getString(SecureStorageService.prefsInstallMarker);
      final deviceId = keychain.items[SecureStorageService.keyDeviceId];
      await backgroundAndLock(tester);

      await app.read(sessionProvider.notifier).logout();
      await tester.pump();
      expect(app.read(sessionProvider).value, isNull);
      expect(keychain.mutationsWhileLocked, 0, reason: 'nothing half-deleted');
      expect(keychain.items[SecureStorageService.keySession], isNotNull);
      expect(prefs.getString(SecureStorageService.prefsPendingSignOut), 'all');
      // Reads already answer "signed out".
      expect(await app.read(secureStorageProvider).loadSession(), isNull);

      await unlockAndReturn(tester);
      expect(find.byType(SetupScreen), findsOneWidget);
      for (final key in [
        SecureStorageService.keySession,
        SecureStorageService.keyEncryptedUserKey,
        SecureStorageService.keyBiometricStorageKey,
      ]) {
        expect(keychain.items.containsKey(key), isFalse, reason: key);
      }
      expect(
          keychain.items.keys.where(
              (k) => k.startsWith(SecureStorageService.historyKeyPrefix)),
          isEmpty);
      expect(keychain.items[SecureStorageService.keyDeviceId], deviceId);
      expect(keychain.items[SecureStorageService.keyInstallMarker], marker);
      expect(prefs.getString(SecureStorageService.prefsPendingSignOut), isNull);
      expect(prefs.getString(SecureStorageService.prefsInstallMarker), marker);
      expect(keychain.mutationsWhileLocked, 0);
    });

    testWidgets('a logout while locked survives the process ending',
        (tester) async {
      final app = await signedIn(tester);
      final marker = prefs.getString(SecureStorageService.prefsInstallMarker);
      await backgroundAndLock(tester);
      await app.read(sessionProvider.notifier).logout();
      await tester.pump();

      // The process ends; the app is opened again and its first reads run
      // before protected data is available…
      await endProcess(tester);
      _setLifecycle(tester, AppLifecycleState.resumed);
      var (again, wiped) = await _start(tester,
          keychain: keychain, prefs: prefs, faceId: faceId);
      expect(wiped, isFalse);
      expect(find.byType(SetupScreen), findsOneWidget,
          reason: 'signed out although the keychain was not cleared yet');
      expect(keychain.items[SecureStorageService.keySession], isNotNull);

      // …and one more start after the phone was unlocked.
      await endProcess(tester);
      keychain.locked = false;
      _setLifecycle(tester, AppLifecycleState.resumed);
      (again, wiped) = await _start(tester,
          keychain: keychain, prefs: prefs, faceId: faceId);
      expect(wiped, isFalse, reason: 'a sign-out never looks like a reinstall');
      expect(find.byType(SetupScreen), findsOneWidget);
      expect(again.read(sessionProvider).value, isNull);
      expect(
          keychain.items.containsKey(SecureStorageService.keySession), isFalse);
      expect(
          keychain.items.containsKey(SecureStorageService.keyEncryptedUserKey),
          isFalse);
      expect(keychain.items[SecureStorageService.keyInstallMarker], marker);
      expect(prefs.getString(SecureStorageService.prefsPendingSignOut), isNull);
      expect(keychain.mutationsWhileLocked, 0);
    });
  });
}
