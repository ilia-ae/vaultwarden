import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_approver/demo_runtime.dart';
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/screens/pin/pin_prefs.dart';
import 'package:vault_approver/screens/pin/pin_section.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';
import 'package:vault_approver/screens/requests_screen.dart';
import 'package:vault_approver/widgets/glass_top_bar.dart';

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

  testWidgets('2nd tab: title, refresh, demo FAB and FLAG_SECURE by tab',
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

    // Top bar: Vault, PIN. Inside Vault: the Pending/History segments.
    for (final id in ['tab_vault', 'tab_pin', 'tab_pending', 'tab_history']) {
      expect(byId(id), findsOneWidget, reason: id);
    }
    expect(find.text(l.vaultTab), findsOneWidget);
    expect(find.text(l.pinTab), findsOneWidget);
    expect(find.text(l.authRequestsTitle), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(byId('btn_add_demo'), findsOneWidget);
    expect(secureCalls(channel), isEmpty);

    // History is a segment inside the Vault tab, not a tab of its own.
    await tapTab(tester, 'tab_history');
    expect(byId('btn_add_demo'), findsNothing,
        reason: 'FAB only on Vault › Pending');
    expect(find.text(l.authRequestsTitle), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(secureCalls(channel), isEmpty);
    expect(pinTabVisible.value, isFalse);

    await tapTab(tester, 'tab_pin');
    expect(find.text(l.pinTitle), findsOneWidget);
    expect(find.text(l.authRequestsTitle), findsNothing);
    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(byId('btn_add_demo'), findsNothing);
    expect(byId('tab_pending'), findsNothing,
        reason: 'the Pending/History picker is Vault\'s');
    expect(byId('pin_tool_pin24'), findsOneWidget);
    expect(pinTabVisible.value, isTrue);
    // The tab opens on PIN Shift, its PIN field first.
    expect(byId('pin_shift_view'), findsOneWidget);
    expect(byId('pin_shift_pin'), findsOneWidget);
    // The screen (by tab index) and the section (while it exists) both hold
    // FLAG_SECURE; the calls nest.
    expect(secureCalls(channel), [true, true]);
    expect(container.exists(pinSessionProvider), isTrue);

    await tapTab(tester, 'tab_vault');
    expect(find.text(l.authRequestsTitle), findsOneWidget);
    expect(pinTabVisible.value, isFalse);
    // Still on while the old page existed, off once the section was gone.
    expect(secureCalls(channel), [true, true, true, false]);
    // Leaving the tab disposed the section's session (and its seed cache).
    expect(container.exists(pinSessionProvider), isFalse);
    // Back on the segment it was left on (History): still no FAB.
    bool selected(String id) =>
        tester.widget<Semantics>(byId(id)).properties.selected!;
    expect(selected('tab_history'), isTrue);
    expect(selected('tab_pending'), isFalse);
    expect(byId('btn_add_demo'), findsNothing);
    await tapTab(tester, 'tab_pending');
    expect(selected('tab_pending'), isTrue);
    expect(byId('btn_add_demo'), findsOneWidget);
    expect(secureCalls(channel), [true, true, true, false]);

    // Unmounting while on the PIN tab releases FLAG_SECURE.
    await tapTab(tester, 'tab_pin');
    expect(secureCalls(channel).last, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(secureCalls(channel).last, isFalse);
  });

  Future<ProviderContainer> pumpRequests(WidgetTester tester,
      {Locale locale = const Locale('en')}) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [pinComputeRunnerProvider.overrideWithValue(inlineRunner)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: const RequestsScreen(),
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
    await tester.tap(byId('pin_tool_pin24'));
    await tester.pump();
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

    await tapTab(tester, 'tab_vault');
    expect(cache.hasSeed, isFalse, reason: 'zeroed when the tab was left');
    expect(container.exists(pinSessionProvider), isFalse);
    expect(find.byType(EditableText, skipOffstage: false), findsNothing);
    expect(focusInField(), isFalse);
    expect(secureCalls(channel).last, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('PIN Shift keeps its length across tab visits, not its values',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    final container = await pumpRequests(tester);
    String length() => tester
        .widget<Text>(find.descendant(
            of: byId('pin_shift_len_value'), matching: find.byType(Text)))
        .data!;

    await tapTab(tester, 'tab_pin');
    expect(byId('pin_shift_view'), findsOneWidget);
    expect(length(), '8');
    await tester.ensureVisible(byId('pin_shift_len_6'));
    await tester.tap(byId('pin_shift_len_6'));
    await tester.pump();
    await tester.enterText(fieldById('pin_shift_pin'), '123456');
    await tester.enterText(fieldById('pin_shift_vector'), '111111');
    await tester.pump();

    await tapTab(tester, 'tab_vault');
    expect(container.exists(pinSessionProvider), isFalse);
    await tapTab(tester, 'tab_pin');
    expect(byId('pin_shift_view'), findsOneWidget);
    expect(length(), '6');
    expect(fieldText(tester, 'pin_shift_pin'), isEmpty);
    expect(fieldText(tester, 'pin_shift_vector'), isEmpty);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(PinPrefs.kShiftLength), 6);
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

    await tapTab(tester, 'tab_vault');
    expect(find.text(l.pinYkRandomErasedLeft), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  // FLAG_SECURE covers any part of the PIN tab on screen — now the 2nd tab,
  // so the first pixel of a swipe away from Vault already counts.
  testWidgets('mid-swipe from Vault towards PIN: secure, then released',
      (tester) async {
    useTallSurface(tester);
    final channel = mockPrivacyChannel(tester);
    await pumpRequests(tester);
    expect(pinTabVisible.value, isFalse);

    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(TabBarView)));
    await gesture.moveBy(const Offset(-40, 0));
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(pinTabVisible.value, isTrue);
    expect(secureCalls(channel).first, isTrue);

    // Dragged back and let go: Vault again, the PIN page wiped and gone.
    await gesture.moveBy(const Offset(100, 0));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(pinTabVisible.value, isFalse);
    expect(secureCalls(channel).last, isFalse);
    expect(byId('tab_pending'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final (locale, rtl) in [
    (const Locale('en'), false),
    (const Locale('ar'), true)
  ]) {
    testWidgets(
        'the top tabs: text labels, the underline under the active one '
        '(${locale.languageCode})', (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpRequests(tester, locale: locale);
      final l = lookupAppLocalizations(locale);
      // No droplet: the bar's own glass is the only glass in it.
      expect(
        find.descendant(
            of: find.byType(GlassTopBar),
            matching: find.byType(GlassContainer)),
        findsOneWidget,
      );
      Rect underline() => tester.getRect(find.byKey(GlassTopBar.underlineKey));
      Rect label(String text) => tester.getRect(find.descendant(
          of: find.byType(GlassTopBar), matching: find.text(text)));

      // 1000-pt wide surface; the tab row has 16-pt margins.
      expect(
          underline().center.dx, moreOrLessEquals(label(l.vaultTab).center.dx),
          reason: 'on Vault');
      expect(underline().width, moreOrLessEquals(label(l.vaultTab).width));
      expect(tester.getCenter(byId('tab_vault')).dx < 500, !rtl);

      await tapTab(tester, 'tab_pin');
      expect(underline().center.dx, moreOrLessEquals(label(l.pinTab).center.dx),
          reason: 'on PIN');
      expect(underline().width,
          moreOrLessEquals(math.max(label(l.pinTab).width, 24)));
      expect(tester.getCenter(byId('tab_pin')).dx > 500, !rtl);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
