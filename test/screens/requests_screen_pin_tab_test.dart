import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/demo_runtime.dart';
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';
import 'package:vault_approver/screens/requests_screen.dart';

import 'pin/pin_harness.dart';

/// The `enabled` argument of every `setSecureScreen` call so far.
List<Object?> secureCalls(PrivacyChannelLog log) => [
      for (final c in log.named('setSecureScreen'))
        (c.arguments as Map)['enabled'],
    ];

Future<void> tapTab(WidgetTester tester, String id) async {
  await tester.tap(byId(id));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
  // A page first built in the last animation frame loads its prefs after it.
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() {
    setPinPrefs();
    // Demo data: no network, no biometrics, fixture requests and history.
    demoRuntime.value = true;
  });
  tearDown(() => demoRuntime.value = false);

  testWidgets('3rd tab: title, refresh, demo FAB and FLAG_SECURE by tab',
      (tester) async {
    useTallSurface(tester);
    final channel = mockPrivacyChannel(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [pinComputeRunnerProvider.overrideWithValue(inlineRunner)],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: RequestsScreen(),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final l = AppLocalizations.of(tester.element(find.byType(RequestsScreen)))!;
    final container =
        ProviderScope.containerOf(tester.element(find.byType(RequestsScreen)));

    for (final id in ['tab_pending', 'tab_history', 'tab_pin']) {
      expect(byId(id), findsOneWidget, reason: id);
    }
    expect(find.text(l.pinTab), findsOneWidget);
    expect(find.text(l.authRequestsTitle), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(byId('btn_add_demo'), findsOneWidget);
    expect(secureCalls(channel), isEmpty);

    await tapTab(tester, 'tab_history');
    expect(byId('btn_add_demo'), findsNothing, reason: 'FAB only on tab 0');
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(secureCalls(channel), isEmpty);

    await tapTab(tester, 'tab_pin');
    expect(find.text(l.pinTitle), findsOneWidget);
    expect(find.text(l.authRequestsTitle), findsNothing);
    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(byId('btn_add_demo'), findsNothing);
    expect(byId('pin_tool_pin24'), findsOneWidget);
    // The screen (by tab index) and the section (while it exists) both hold
    // FLAG_SECURE; the calls nest.
    expect(secureCalls(channel), [true, true]);
    expect(container.exists(pinSessionProvider), isTrue);

    await tapTab(tester, 'tab_pending');
    expect(find.text(l.authRequestsTitle), findsOneWidget);
    expect(byId('btn_add_demo'), findsOneWidget);
    // Still on while the old page existed, off once the section was gone.
    expect(secureCalls(channel), [true, true, true, false]);
    // Leaving the tab disposed the section's session (and its seed cache).
    expect(container.exists(pinSessionProvider), isFalse);

    // Unmounting while on the PIN tab releases FLAG_SECURE.
    await tapTab(tester, 'tab_pin');
    expect(secureCalls(channel).last, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(secureCalls(channel).last, isFalse);
  });

  Future<ProviderContainer> pumpRequests(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [pinComputeRunnerProvider.overrideWithValue(inlineRunner)],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: RequestsScreen(),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return ProviderScope.containerOf(
        tester.element(find.byType(RequestsScreen)));
  }

  // Security #4: a focused field keeps its page alive offscreen; leaving the
  // tab must still unfocus, wipe and dispose everything.
  testWidgets('leaving the PIN tab with a focused field wipes and disposes',
      (tester) async {
    useTallSurface(tester);
    final channel = mockPrivacyChannel(tester);
    final container = await pumpRequests(tester);

    await tapTab(tester, 'tab_pin');
    await tester.enterText(fieldById('pin24_nickname'), 'visa');
    await tester.pump();
    await tester.enterText(fieldById('pin24_seed'), abandon12);
    await settleDerivation(tester);
    final cache = container.read(pinSeedProvider);
    expect(cache.hasSeed, isTrue);
    bool focusInField() =>
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorStateOfType<EditableTextState>() !=
        null;
    expect(focusInField(), isTrue, reason: 'the seed field has focus');

    await tapTab(tester, 'tab_pending');
    expect(cache.hasSeed, isFalse, reason: 'zeroed when the tab was left');
    expect(container.exists(pinSessionProvider), isFalse);
    expect(find.byType(EditableText, skipOffstage: false), findsNothing);
    expect(focusInField(), isFalse);
    expect(secureCalls(channel).last, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('leaving the tab with random YubiKey values says they are gone',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpRequests(tester);
    final l = AppLocalizations.of(tester.element(find.byType(RequestsScreen)))!;

    await tapTab(tester, 'tab_pin');
    await tester.tap(byId('pin_tool_yubikey'));
    await tester.pump();
    await tester.ensureVisible(byId('yk_source_random'));
    await tester.tap(byId('yk_source_random'));
    await tester.pump();
    await tester.enterText(fieldById('yk_serials'), '12345678');
    await settleDerivation(tester);
    expect(byId('yk_random_warning'), findsOneWidget);
    expect(l.pinYkRandomWarning, contains('PIN tab'));

    await tapTab(tester, 'tab_history');
    expect(find.text(l.pinYkRandomErasedLeft), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
