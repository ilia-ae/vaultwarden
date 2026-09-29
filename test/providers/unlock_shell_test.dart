import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<bool> authenticate({
    String reason = 'Authenticate to access Vault Approver',
  }) async {
    prompts++;
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
}
