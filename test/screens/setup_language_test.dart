// The setup (first sign-in) screen has a language menu next to its theme
// toggle: the settings sheet's choices, applied to the form at once, saved
// like the settings sheet saves them, and still in effect once signed in.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_approver/app.dart';
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/providers/service_providers.dart';
import 'package:vault_approver/providers/session_provider.dart';
import 'package:vault_approver/screens/requests_screen.dart';
import 'package:vault_approver/screens/setup_screen.dart';
import 'package:vault_approver/services/settings_service.dart';
import 'package:vault_approver/widgets/client_cert_section.dart';

import '../providers/provider_fakes.dart';
import 'pin/pin_harness.dart' show byId, mockPrivacyChannel;
import 'screen_harness.dart';

final _en = lookupAppLocalizations(const Locale('en'));
final _ru = lookupAppLocalizations(const Locale('ru'));
final _ar = lookupAppLocalizations(const Locale('ar'));

/// The real App (not a fixed-locale test app), signed out: the setup screen
/// on an 874-pt iPhone.
Future<Harness> _pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(402 * 3, 874 * 3);
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
  addTearDown(tester.view.reset);
  PackageInfo.setMockInitialValues(
    appName: 'Vault Approver',
    packageName: 'com.vaultapprover.app',
    version: '1.0.5',
    buildNumber: '35',
    buildSignature: '',
  );
  mockPrivacyChannel(tester);
  final h = await Harness.create(overrides: [
    biometricServiceProvider.overrideWithValue(FakeBiometrics()),
    clientCertServiceProvider.overrideWithValue(FakeClientCertService()),
    certificateFilePickerProvider.overrideWithValue(FakePicker(null).call),
  ]);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: h.container,
    child: const App(),
  ));
  await tester.pump();
  await tester.pump();
  expect(find.byType(SetupScreen), findsOneWidget);
  return h;
}

Future<void> _finish(WidgetTester tester, Harness h) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  h.dispose();
}

Future<void> _choose(WidgetTester tester, String label) async {
  await tester.tap(byId('btn_language'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<Locale?> _storedLocale() async =>
    SettingsService(await SharedPreferences.getInstance()).locale;

bool _checked(WidgetTester tester, String label) => tester
    .widget<CheckedPopupMenuItem<int>>(find.ancestor(
      of: find.text(label),
      matching: find.byType(CheckedPopupMenuItem<int>),
    ))
    .checked;

void main() {
  testWidgets('language menu: the form switches at once, the choice is saved',
      (tester) async {
    final h = await _pumpApp(tester);
    expect(find.text(_en.setUp), findsOneWidget);

    // In the app bar, right next to the theme toggle.
    final language = tester.getRect(byId('btn_language'));
    final theme = tester.getRect(byId('btn_theme'));
    expect(language.center.dy, theme.center.dy);
    expect(language.right, lessThanOrEqualTo(theme.left));
    expect(theme.left - language.right, lessThan(8));

    // The settings sheet's choices; the device language is the current one.
    await tester.tap(byId('btn_language'));
    await tester.pumpAndSettle();
    for (final option in appLanguageOptions(_en)) {
      expect(find.text(option.label), findsOneWidget, reason: option.label);
    }
    expect(_checked(tester, _en.languageSystem), isTrue);
    expect(_checked(tester, 'Русский'), isFalse);
    await tester.tap(find.text('Русский'));
    await tester.pumpAndSettle();

    expect(find.text(_ru.setUp), findsOneWidget);
    expect(find.text(_ru.setupSubtitle), findsOneWidget);
    expect(find.text(_en.setUp), findsNothing);
    expect(h.container.read(localeProvider), const Locale('ru'));
    expect(await _storedLocale(), const Locale('ru'));

    await tester.tap(byId('btn_language'));
    await tester.pumpAndSettle();
    expect(_checked(tester, 'Русский'), isTrue);
    expect(_checked(tester, _ru.languageSystem), isFalse);
    await tester.tap(find.text('العربية').last);
    await tester.pumpAndSettle();
    expect(find.text(_ar.setUp), findsOneWidget);
    expect(Directionality.of(tester.element(find.text(_ar.setUp))),
        TextDirection.rtl);
    expect(await _storedLocale(), const Locale('ar'));

    // "System" follows the device again (en in tests) and forgets the choice.
    await _choose(tester, _ar.languageSystem);
    expect(find.text(_en.setUp), findsOneWidget);
    expect(h.container.read(localeProvider), isNull);
    expect(await _storedLocale(), isNull);
    await _finish(tester, h);
  });

  testWidgets('the language picked before signing in stays after sign-in',
      (tester) async {
    final h = await _pumpApp(tester);
    final protectedKey = await h.protectedUserKey();
    h.api.onLogin = (_) => {
          'access_token': 'at',
          'refresh_token': 'rt',
          'expires_in': 3600,
          'Key': protectedKey,
        };
    await _choose(tester, 'Русский');

    await tester.enterText(
        find.widgetWithText(TextFormField, _ru.serverUrlLabel), kServer);
    await tester.enterText(
        find.widgetWithText(TextFormField, _ru.emailLabel), kEmail);
    await tester.enterText(
        find.widgetWithText(TextFormField, _ru.masterPasswordLabel), kPassword);
    await tester.tap(find.text(_ru.setUp));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(h.container.read(sessionProvider).value, isNotNull);
    expect(find.byType(RequestsScreen), findsOneWidget);
    expect(find.text(_ru.authRequestsTitle), findsOneWidget);
    expect(find.text(_ru.pendingTab), findsOneWidget);
    expect(await _storedLocale(), const Locale('ru'));
    await _finish(tester, h);
  });
}
