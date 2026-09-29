// The setup screen on an 874-pt iPhone: "Set Up" is pinned under the
// scrolling form, so it is on screen with the self-hosted form and a
// certificate card, and above the keyboard; the version footer (5-tap demo
// gesture) stays reachable when the keyboard is down.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:vault_approver/providers/service_providers.dart';
import 'package:vault_approver/screens/setup_screen.dart';
import 'package:vault_approver/services/client_cert_service.dart';
import 'package:vault_approver/widgets/client_cert_section.dart';

import '../providers/provider_fakes.dart';
import 'screen_harness.dart';

final _l = en();
const _screenH = 874.0;
const _homeIndicator = 34.0;
const _keyboardH = 336.0;

Future<(Harness, FakeClientCertService)> _pump(WidgetTester tester) async {
  tester.view.physicalSize = const Size(402 * 3, _screenH * 3);
  tester.view.devicePixelRatio = 3;
  tester.view.padding =
      const FakeViewPadding(top: 62 * 3, bottom: _homeIndicator * 3);
  addTearDown(tester.view.reset);
  PackageInfo.setMockInitialValues(
    appName: 'Vault Approver',
    packageName: 'com.vaultapprover.app',
    version: '1.0.5',
    buildNumber: '35',
    buildSignature: '',
  );
  final certs = FakeClientCertService();
  final h = await Harness.create(overrides: [
    biometricServiceProvider.overrideWithValue(FakeBiometrics()),
    clientCertServiceProvider.overrideWithValue(certs),
    certificateFilePickerProvider.overrideWithValue(FakePicker(null).call),
  ]);
  await tester.pumpWidget(testApp(h.container, const SetupScreen()));
  await tester.pump();
  await tester.pump();
  return (h, certs);
}

Future<void> _finish(WidgetTester tester, Harness h) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  h.dispose();
}

final _setUp = find.widgetWithText(FilledButton, _l.setUp);
final _version = find.text('v1.0.5 (35)');

/// The button is fully on screen above [bottom] and a tap on its centre
/// reaches it (nothing covers it).
void _expectReachable(WidgetTester tester, Finder finder, double bottom) {
  final rect = tester.getRect(finder);
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(rect.bottom, lessThanOrEqualTo(bottom));
  expect(finder.hitTestable(), findsOneWidget);
}

void main() {
  testWidgets('self-hosted form: Set Up and the version footer are on screen',
      (tester) async {
    final (h, _) = await _pump(tester);
    expect(find.text(_l.clientCertTitle), findsOneWidget);
    _expectReachable(tester, _setUp, _screenH - _homeIndicator);
    _expectReachable(tester, _version, _screenH - _homeIndicator);
    expect(tester.getRect(_version).top,
        greaterThan(tester.getRect(_setUp).bottom));
    await _finish(tester, h);
  });

  testWidgets(
      'with a certificate card the form scrolls, Set Up stays on screen',
      (tester) async {
    final (h, certs) = await _pump(tester);
    certs.stored[ClientCertService.originOf(kServer)] = ClientCertificateInfo(
      commonName: 'e2e-final-client',
      issuer: 'CN=E2E Final Throwaway CA',
      notAfter: DateTime.now().toUtc().add(const Duration(days: 400)),
    );
    await tester.enterText(
        find.widgetWithText(TextFormField, _l.serverUrlLabel), kServer);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.text('e2e-final-client'), findsOneWidget);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();

    _expectReachable(tester, _setUp, _screenH - _homeIndicator);
    _expectReachable(tester, _version, _screenH - _homeIndicator);
    // The password field is below the fold: the form scrolls above the
    // pinned button instead of pushing it off screen.
    final password = tester
        .getRect(find.widgetWithText(TextFormField, _l.masterPasswordLabel));
    expect(password.bottom, greaterThan(tester.getRect(_setUp).top));
    await tester.scrollUntilVisible(
        find.widgetWithText(TextFormField, _l.masterPasswordLabel), 100,
        scrollable: find.byType(Scrollable).first);
    expect(
      find.widgetWithText(TextFormField, _l.masterPasswordLabel).hitTestable(),
      findsOneWidget,
    );
    await _finish(tester, h);
  });

  testWidgets('keyboard up: Set Up sits above it, the footer steps aside',
      (tester) async {
    final (h, _) = await _pump(tester);
    await tester
        .showKeyboard(find.widgetWithText(TextFormField, _l.emailLabel));
    tester.view.viewInsets = const FakeViewPadding(bottom: _keyboardH * 3);
    await tester.pump();
    _expectReachable(tester, _setUp, _screenH - _keyboardH);
    expect(_version, findsNothing);

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    _expectReachable(tester, _version, _screenH - _homeIndicator);
    await _finish(tester, h);
  });

  testWidgets('Set Up with an invalid field out of view scrolls it back',
      (tester) async {
    final (h, _) = await _pump(tester);
    await tester.enterText(
        find.widgetWithText(TextFormField, _l.serverUrlLabel), kServer);
    // A short form viewport (keyboard up), scrolled to the top: the e-mail
    // and password fields are below the pinned button.
    tester.view.viewInsets = const FakeViewPadding(bottom: _keyboardH * 3);
    await tester.pump();
    final scrollable = find.byType(Scrollable).first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pump();
    final setUpTop = tester.getRect(_setUp).top;
    expect(
      tester.getRect(find.widgetWithText(TextFormField, _l.emailLabel)).top,
      greaterThan(setUpTop),
      reason: 'precondition: the e-mail field is out of view',
    );

    await tester.tap(_setUp);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final email = tester.getRect(find.text(_l.emailRequired));
    expect(email.bottom, lessThan(setUpTop));
    expect(email.top, greaterThan(0));
    expect(h.api.preloginUrls, isEmpty, reason: 'nothing was sent');
    tester.view.viewInsets = FakeViewPadding.zero;
    await _finish(tester, h);
  });
}
