import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/app.dart';
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/providers/service_providers.dart';
import 'package:vault_approver/providers/session_provider.dart';
import 'package:vault_approver/services/biometric_service.dart';
import 'package:vault_approver/services/secure_storage_service.dart';
import 'package:vault_approver/widgets/unlock_shell.dart';

import 'provider_fakes.dart';

class _FakeBiometrics extends Fake implements BiometricService {
  int prompts = 0;
  bool succeed = false;

  /// Runs during the prompt (e.g. the device locks meanwhile).
  void Function()? onPrompt;

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> authenticate({
    String reason = 'Authenticate to access Vault Approver',
  }) async {
    prompts++;
    onPrompt?.call();
    return succeed;
  }
}

Future<(Harness, _FakeBiometrics)> _harness() async {
  final bio = _FakeBiometrics();
  final h = await Harness.create(
    overrides: [biometricServiceProvider.overrideWithValue(bio)],
  );
  return (h, bio);
}

/// A signed-in account (as 1.0.5 left it) in an iOS-like keychain.
Future<(Harness, _FakeBiometrics, FakeAppleKeychain)> _iosHarness() async {
  final bio = _FakeBiometrics()..succeed = true;
  final keychain = FakeAppleKeychain();
  final h = await Harness.create(
    storage: appleStorage(keychain),
    overrides: [biometricServiceProvider.overrideWithValue(bio)],
  );
  await seedAsBuild105(keychain, h.crypto);
  await h.container.read(sessionProvider.future);
  return (h, bio, keychain);
}

final _keyMissingText =
    lookupAppLocalizations(const Locale('en')).lockKeyMissing;

void _resumeOnTearDown(WidgetTester tester) => addTearDown(() =>
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));

Widget _shell(ProviderContainer c, {required bool locked}) =>
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: UnlockShell(
          locked: locked,
          child: const LockSkeleton(),
        ),
      ),
    );

void main() {
  testWidgets('missing user key: the lock screen offers Log out (F7)',
      (tester) async {
    final (h, bio) = await _harness();
    await h.seedAccount();
    // A session without the encrypted user key (the state a demo leak could
    // leave behind): unlocking can never succeed.
    await h.raw.delete(key: SecureStorageService.keyEncryptedUserKey);
    await h.container.read(sessionProvider.future);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    await tester.pumpWidget(_shell(h.container, locked: true));
    await tester.pumpAndSettle();
    expect(find.text('Logout'), findsOneWidget);
    expect(bio.prompts, 0, reason: 'no pointless Face ID prompt');

    await tester.tap(find.text('Logout'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Logout').last);
    await tester.pumpAndSettle();
    expect(h.container.read(sessionProvider).value, isNull);
    expect((await h.keychain())[SecureStorageService.keyDeviceId], isNotNull);
    h.dispose();
  });

  testWidgets('relock during the reveal re-prompts biometrics (R8)',
      (tester) async {
    final (h, bio) = await _harness();
    await h.seedAccount();
    await h.container.read(sessionProvider.future);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

    await tester.pumpWidget(_shell(h.container, locked: true));
    await tester.pump();
    await tester.pump();
    expect(bio.prompts, 1); // automatic prompt on first show
    await tester.pump(const Duration(seconds: 5)); // failure snackbar

    // Unlocked: the veil starts evaporating (~700 ms)…
    await tester.pumpWidget(_shell(h.container, locked: false));
    await tester.pump(const Duration(milliseconds: 100));
    // …and the app relocks before it finishes.
    await tester.pumpWidget(_shell(h.container, locked: true));
    await tester.pump();
    await tester.pump();
    expect(bio.prompts, 2);

    await tester.pumpAndSettle();
    h.dispose();
  });

  // lockKeyMissing on 1.1.0: the lock screen read the key at its first
  // frame back from the background — before iOS makes the keychain
  // available again — took the plugin's null for "missing" and offered
  // nothing but "Log out".
  group('keychain not available yet is not a missing key', () {
    testWidgets('lock screen shown while the keychain is still locked',
        (tester) async {
      _resumeOnTearDown(tester);
      final (h, bio, keychain) = await _iosHarness();
      // willEnterForeground: the first frame (inactive) mounts the lock
      // screen while protected data is still unavailable.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      keychain.locked = true;
      await tester.pumpWidget(_shell(h.container, locked: true));
      await tester.pump();
      await tester.pump();
      expect(find.text(_keyMissingText), findsNothing);
      expect(find.text('Logout'), findsNothing);
      expect(bio.prompts, 0, reason: 'no prompt before the app is active');

      keychain.locked = false; // didBecomeActive / protected data available
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(bio.prompts, 1);
      expect(h.container.read(userKeyProvider), Harness.userKey);
      expect(h.container.read(isLockedProvider), isFalse);
      expect(find.text(_keyMissingText), findsNothing);
      expect(
          keychain.items[SecureStorageService.keyEncryptedUserKey], isNotNull);
      await tester.pumpAndSettle();
      h.dispose();
    });

    testWidgets('key unreadable right after Face ID: an error, then Unlock',
        (tester) async {
      _resumeOnTearDown(tester);
      final (h, bio, keychain) = await _iosHarness();
      // The device locks while the Face ID sheet is up.
      bio.onPrompt = () => keychain.locked = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(_shell(h.container, locked: true));
      await tester.pump();
      await tester.pump();
      expect(bio.prompts, 1);
      expect(find.text(_keyMissingText), findsNothing);
      expect(find.textContaining("couldn't be read"), findsOneWidget);
      expect(h.container.read(userKeyProvider), isNull);

      bio.onPrompt = null;
      keychain.locked = false;
      await tester.pump(const Duration(seconds: 5)); // SnackBar gone
      await tester.tap(find.text('Unlock'));
      await tester.pump();
      await tester.pump();
      expect(bio.prompts, 2);
      expect(h.container.read(userKeyProvider), Harness.userKey);
      await tester.pumpAndSettle();
      h.dispose();
    });

    testWidgets('"key missing" is checked again on resume and by Retry',
        (tester) async {
      _resumeOnTearDown(tester);
      final (h, bio, keychain) = await _iosHarness();
      final key =
          keychain.items.remove(SecureStorageService.keyEncryptedUserKey)!;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(_shell(h.container, locked: true));
      await tester.pumpAndSettle();
      expect(find.text(_keyMissingText), findsOneWidget);
      expect(find.text('Logout'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(bio.prompts, 0);

      // Retry while it is still gone: nothing changes, no prompt.
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text(_keyMissingText), findsOneWidget);
      expect(bio.prompts, 0);

      // Back from the background with the key readable again.
      keychain.items[SecureStorageService.keyEncryptedUserKey] = key;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(find.text(_keyMissingText), findsNothing);
      expect(bio.prompts, 1);
      expect(h.container.read(userKeyProvider), Harness.userKey);
      await tester.pumpAndSettle();
      h.dispose();
    });
  });
}
