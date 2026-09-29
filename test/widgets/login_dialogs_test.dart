import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/widgets/login_dialogs.dart';

final _l = lookupAppLocalizations(const Locale('en'));

void main() {
  group('TwoFactorProvider.choices (F12, A6)', () {
    test('drops "remember", appends the recovery code, supported first', () {
      expect(TwoFactorProvider.choices([7, 5, 0, 1]), [0, 1, 7, 8]);
      expect(TwoFactorProvider.choices([0]), [0, 8]);
      expect(TwoFactorProvider.choices([8, 3, 3]), [3, 8]);
    });

    test('only one usable method is chosen automatically', () {
      expect(TwoFactorProvider.automaticChoice([0, 8]), 0);
      expect(TwoFactorProvider.automaticChoice([3, 7, 8]), 3);
      expect(TwoFactorProvider.automaticChoice([0, 1, 8]), isNull);
      expect(TwoFactorProvider.automaticChoice([7, 2, 8]), isNull);
    });

    test('supported methods', () {
      expect(
        [0, 1, 2, 3, 4, 5, 6, 7, 8].where(TwoFactorProvider.isSupported),
        [0, 1, 3, 8],
      );
    });
  });

  group('VerificationCodeKind', () {
    test('recovery codes are compared without spaces, lowercase', () {
      expect(
        VerificationCodeKind.recoveryCode.normalize(' ABCD efgh 1234 \n'),
        'abcdefgh1234',
      );
      expect(VerificationCodeKind.totp.normalize(' 123456 '), '123456');
    });

    test('lengths', () {
      expect(VerificationCodeKind.totp.maxLength, 6);
      expect(VerificationCodeKind.yubiKey.minLength, 44);
      expect(VerificationCodeKind.newDeviceOtp.maxLength, 8);
      expect(VerificationCodeKind.totp.autoSubmit, isTrue);
      expect(VerificationCodeKind.email.autoSubmit, isFalse);
    });
  });

  testWidgets('a rejected code keeps the dialog open; accepted closes it',
      (tester) async {
    final submitted = <String>[];
    VerificationDialogResult? result;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showVerificationCodeDialog(
              context,
              kind: VerificationCodeKind.yubiKey,
              title: 'YubiKey',
              message: 'Touch it',
              onSubmit: (code, remember) async {
                submitted.add(code);
                return code.startsWith('x')
                    ? const CodeRejected('Bad OTP')
                    : const CodeAccepted();
              },
            );
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Too short: local validation, nothing submitted.
    await tester.enterText(find.byType(TextField), 'cccc');
    await tester.tap(find.text(_l.verify));
    await tester.pumpAndSettle();
    expect(find.text(_l.codeIncomplete), findsOneWidget);
    expect(submitted, isEmpty);

    // A YubiKey types all 44 characters: auto-submitted.
    await tester.enterText(find.byType(TextField), 'x' * 44);
    await tester.pumpAndSettle();
    expect(submitted, ['x' * 44]);
    expect(find.text('Bad OTP'), findsOneWidget);
    expect(find.text('YubiKey'), findsOneWidget, reason: 'still open');

    await tester.enterText(find.byType(TextField), 'c' * 44);
    await tester.pumpAndSettle();
    expect(submitted.last, 'c' * 44);
    expect(find.text('YubiKey'), findsNothing);
    expect(result?.outcome, VerificationDialogOutcome.accepted);
  });
}
