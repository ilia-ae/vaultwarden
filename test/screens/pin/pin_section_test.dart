import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_approver/screens/pin/pin_prefs.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';

import 'pin_harness.dart';

void main() {
  setUp(setPinPrefs);

  testWidgets('tool picker: PIN 24 → PIN Shift → YubiKey; legacy on demand',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    final l = l10n(tester);

    final ids = ['pin_tool_pin24', 'pin_tool_shift', 'pin_tool_yubikey'];
    final xs = [for (final id in ids) tester.getCenter(byId(id)).dx];
    expect(xs, orderedEquals([...xs]..sort()));
    expect(byId('pin_tool_legacy'), findsNothing);
    expect(byId('pin24_seed'), findsOneWidget);

    await tester.tap(byId('pin_tool_shift'));
    await tester.pump();
    expect(find.text(l.pinComingSoon), findsOneWidget);
    expect(byId('pin24_seed'), findsNothing);
    await tester.tap(byId('pin_tool_yubikey'));
    await tester.pump();
    expect(find.text(l.pinComingSoon), findsOneWidget);

    await tester.tap(byId('pin_show_legacy'));
    await tester.pump();
    expect(byId('pin_tool_legacy'), findsOneWidget);
    expect(tester.getCenter(byId('pin_tool_legacy')).dx,
        greaterThan(tester.getCenter(byId('pin_tool_yubikey')).dx));
    await tester.tap(byId('pin_tool_legacy'));
    await tester.pump();
    expect(find.text(l.pinToolLegacy), findsWidgets);
    expect(find.text(l.pinComingSoon), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PinPrefs.kShowLegacy), isTrue);

    // Hiding legacy tools while one is open falls back to PIN 24.
    await tester.tap(byId('pin_show_legacy'));
    await tester.pump();
    expect(byId('pin_tool_legacy'), findsNothing);
    expect(byId('pin24_seed'), findsOneWidget);
  });

  testWidgets('the seed cached by PIN 24 is shown and wipeable elsewhere',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    final container = await pumpPin(tester);
    final l = l10n(tester);

    await enterPin24(tester, seed: abandon12, nickname: 'visa');
    final cache = container.read(pinSeedProvider);
    expect(cache.hasSeed, isTrue);
    expect(cache.wordCount, 12);

    await tester.tap(byId('pin_tool_yubikey'));
    await tester.pump();
    expect(find.text(l.pinSeedInMemory(12)), findsOneWidget);
    await tester.tap(byId('pin_wipe_cached_seed'));
    await tester.pump();
    expect(cache.hasSeed, isFalse);
    expect(find.text(l.pinSeedInMemory(12)), findsNothing);
  });

  testWidgets('screen capture covers the tab; screenshot offers a wipe',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    final container = await pumpPin(tester);
    final l = l10n(tester);

    await enterPin24(tester, seed: abandon12, nickname: 'visa');
    await sendPrivacyEvent(tester, true);
    expect(find.text(l.pinHiddenCaptured), findsOneWidget);
    expect(byId('pin24_output'), findsNothing);
    await sendPrivacyEvent(tester, false);
    expect(find.text(l.pinHiddenCaptured), findsNothing);
    expect(displayedPin(tester), '0853');

    await sendPrivacyEvent(tester, 'screenshot');
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text(l.pinScreenshotWarning), findsOneWidget);
    await tester.tap(find.widgetWithText(SnackBarAction, l.pinWipeAction));
    await tester.pump();
    expect(fieldText(tester, 'pin24_seed'), isEmpty);
    expect(container.read(pinSeedProvider).hasSeed, isFalse);
  });

  testWidgets('"Check engine" replays the official vectors', (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    final l = l10n(tester);

    await tester.tap(byId('pin24_selftest'));
    await tester.pump();
    await tester.pump();
    expect(find.text(l.pin24SelfTestOk(10, 10)), findsOneWidget);
  });

  test('PinSession: wipe zeroes the seed and reports content', () {
    final session = PinSession();
    addTearDown(session.dispose);
    var content = false;
    session.registerContentProbe(() => content);
    final events = <PinWipeEvent?>[];
    session.wipes.addListener(() => events.add(session.wipes.value));

    session.wipe(reason: PinWipeReason.user);
    expect(events.single!.hadContent, isFalse);

    content = true;
    session.wipe(scope: PinWipeScope.seed, reason: PinWipeReason.user);
    expect(events.last!.hadContent, isTrue);
    expect(events.last!.scope, PinWipeScope.seed);
    expect(events.last!.serial, 2);
  });
}
