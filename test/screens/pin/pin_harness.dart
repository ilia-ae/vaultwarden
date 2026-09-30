// Shared setup for the PIN tab widget tests (not a test file itself).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/screens/pin/pin_prefs.dart';
import 'package:vault_approver/screens/pin/pin_section.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';
import 'package:vault_approver/services/privacy_service.dart';

/// Public BIP39 test vector (all-zero entropy).
const abandon12 = 'abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon abandon about';

/// Public Speculos default seed (official Ledger app-passwords vectors).
const speculos24 = 'glory promote mansion idle axis finger extra february '
    'uncover one trip resource lawn turtle enact monster seven myth punch '
    'hobby comfort wild raise skin';

/// Runs derivations inline: a widget test's fake clock cannot drive a real
/// isolate.
Future<R> inlineRunner<R>(FutureOr<R> Function() computation) async =>
    await computation();

/// Finds the `Semantics(identifier: id)` widget (Maestro ids).
Finder byId(String id) => find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.identifier == id,
      description: 'Semantics#$id',
    );

/// The editable text inside the field with Semantics identifier [id].
Finder fieldById(String id) =>
    find.descendant(of: byId(id), matching: find.byType(EditableText));

String fieldText(WidgetTester tester, String id) =>
    tester.widget<EditableText>(fieldById(id)).controller.text;

/// Calls the app made on the privacy channel.
class PrivacyChannelLog {
  final List<MethodCall> calls = [];

  Iterable<MethodCall> named(String method) =>
      calls.where((c) => c.method == method);
}

/// Mocks the in-app privacy channels like the native side: every method
/// succeeds, the screen is not captured and, unless
/// [systemShowsCopyConfirmation] (Android 13+), the system does not confirm
/// copies itself (iOS, older Android).
PrivacyChannelLog mockPrivacyChannel(
  WidgetTester tester, {
  bool systemShowsCopyConfirmation = false,
}) {
  final log = PrivacyChannelLog();
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
    const MethodChannel(PrivacyService.channelName),
    (call) async {
      log.calls.add(call);
      return switch (call.method) {
        'isScreenCaptured' => false,
        'systemShowsCopyConfirmation' => systemShowsCopyConfirmation,
        _ => true,
      };
    },
  );
  messenger.setMockMethodCallHandler(
    const MethodChannel(PrivacyService.eventChannelName),
    (call) async => null,
  );
  addTearDown(() {
    messenger.setMockMethodCallHandler(
        const MethodChannel(PrivacyService.channelName), null);
    messenger.setMockMethodCallHandler(
        const MethodChannel(PrivacyService.eventChannelName), null);
  });
  return log;
}

/// Delivers a raw event from the "native" side of the privacy event
/// channel (`true`/`false` capture state or `'screenshot'`).
Future<void> sendPrivacyEvent(WidgetTester tester, Object event) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    PrivacyService.eventChannelName,
    const StandardMethodCodec().encodeSuccessEnvelope(event),
    (_) {},
  );
  await tester.pump();
}

/// A tall surface so every card is on screen without scrolling.
void useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 6000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Moves the app lifecycle to [target] one legal step at a time
/// (resumed ↔ inactive ↔ hidden ↔ paused), as the platform would.
void setLifecycle(WidgetTester tester, AppLifecycleState target) {
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

/// Puts the binding back to `resumed` after a test that changed it.
void resetLifecycleOnTearDown(WidgetTester tester) {
  addTearDown(() => setLifecycle(tester, AppLifecycleState.resumed));
}

/// Sets the stored prefs; the recovery banner is acknowledged by default.
void setPinPrefs([Map<String, Object> values = const {}]) {
  SharedPreferences.setMockInitialValues({
    PinPrefs.kPin24BannerAck: true,
    ...values,
  });
}

/// Pumps the PIN section (or [child]) in a localized app and waits for the
/// prefs to load.
///
/// The tab opens on [tool] as if the user had picked it before; with no
/// [tool] it opens where the app opens it (PIN Shift).
Future<ProviderContainer> pumpPin(
  WidgetTester tester, {
  Widget? child,
  Locale locale = const Locale('en'),
  PinTool? tool,
  List<Override> overrides = const [],
}) async {
  // ProviderScope (not an uncontrolled container) so the container, and with
  // it the section's inactivity timer, is disposed together with the tree.
  await tester.pumpWidget(ProviderScope(
    overrides: [
      pinComputeRunnerProvider.overrideWithValue(inlineRunner),
      if (tool != null) pinToolProvider.overrideWith((_) => tool),
      ...overrides,
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      home: Scaffold(body: child ?? const PinSection()),
    ),
  ));
  await tester.pump();
  await tester.pump();
  return ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
}

/// Lets the 250 ms debounce fire and the (inline) derivation land.
Future<void> settleDerivation(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
  await tester.pump();
}

/// Types the seed and nickname and waits for the result.
Future<void> enterPin24(
  WidgetTester tester, {
  required String seed,
  required String nickname,
  String? passphrase,
}) async {
  await tester.enterText(fieldById('pin24_seed'), seed);
  await tester.pump();
  if (passphrase != null) {
    if (fieldById('pin24_passphrase').evaluate().isEmpty) {
      await tester.tap(byId('pin24_passphrase_section'));
      await tester.pumpAndSettle();
    }
    await tester.enterText(fieldById('pin24_passphrase'), passphrase);
    await tester.pump();
  }
  await tester.enterText(fieldById('pin24_nickname'), nickname);
  await settleDerivation(tester);
}

/// Every Text under the output, joined (digit cells / password chunks).
String outputText(WidgetTester tester) => tester
    .widgetList<Text>(
        find.descendant(of: byId('pin24_output'), matching: find.byType(Text)))
    .map((t) => t.data ?? '')
    .join();

/// The derived PIN as shown in the digit cells.
String displayedPin(WidgetTester tester) =>
    outputText(tester).replaceAll(RegExp(r'[^0-9]'), '');

AppLocalizations l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold).first))!;
