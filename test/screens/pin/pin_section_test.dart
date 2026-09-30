import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_approver/screens/pin/pin_prefs.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';
import 'package:vault_approver/utils/external_picker.dart';

import 'pin_harness.dart';

void main() {
  setUp(setPinPrefs);

  testWidgets(
      'tool picker: PIN Shift → PIN 24 → YubiKey, opens on PIN Shift; '
      'legacy on demand', (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    final container = await pumpPin(tester);
    final l = l10n(tester);

    final ids = ['pin_tool_shift', 'pin_tool_pin24', 'pin_tool_yubikey'];
    final xs = [for (final id in ids) tester.getCenter(byId(id)).dx];
    expect(xs, orderedEquals([...xs]..sort()));
    expect(PinTool.values.first, PinTool.pinShift, reason: 'picker order');
    expect(byId('pin_tool_legacy'), findsNothing);
    // The first tool is the one shown, and it is selected in the picker.
    expect(container.read(pinToolProvider), PinTool.pinShift);
    expect(tester.widget<Semantics>(byId('pin_tool_shift')).properties.selected,
        isTrue);
    expect(byId('pin_shift_view'), findsOneWidget);
    expect(byId('pin24_seed'), findsNothing);

    await tester.tap(byId('pin_tool_pin24'));
    await tester.pump();
    expect(byId('pin24_seed'), findsOneWidget);
    expect(byId('pin_shift_view'), findsNothing);
    await tester.tap(byId('pin_tool_yubikey'));
    await tester.pump();
    expect(byId('yk_view'), findsOneWidget);
    expect(byId('pin24_seed'), findsNothing);

    await tester.tap(byId('pin_show_legacy'));
    await tester.pump();
    expect(byId('pin_tool_legacy'), findsOneWidget);
    expect(tester.getCenter(byId('pin_tool_legacy')).dx,
        greaterThan(tester.getCenter(byId('pin_tool_yubikey')).dx));
    await tester.tap(byId('pin_tool_legacy'));
    await tester.pump();
    expect(find.text(l.pinToolLegacy), findsWidgets);
    expect(byId('legacy_mask_view'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(PinPrefs.kShowLegacy), isTrue);

    // Hiding legacy tools while one is open falls back to the first tool.
    await tester.tap(byId('pin_show_legacy'));
    await tester.pump();
    expect(byId('pin_tool_legacy'), findsNothing);
    expect(byId('pin_shift_view'), findsOneWidget);
    expect(container.read(pinToolProvider), PinTool.pinShift);
  });

  testWidgets('a stored "show legacy" with PIN Shift first; legacy stays last',
      (tester) async {
    setPinPrefs({PinPrefs.kShowLegacy: true});
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);

    final ids = [
      'pin_tool_shift',
      'pin_tool_pin24',
      'pin_tool_yubikey',
      'pin_tool_legacy',
    ];
    final xs = [for (final id in ids) tester.getCenter(byId(id)).dx];
    expect(xs, orderedEquals([...xs]..sort()));
    expect(byId('pin_shift_view'), findsOneWidget);
  });

  testWidgets('PIN Shift: the PIN field sits right under the picker',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    final l = l10n(tester);

    final picker = tester.getRect(byId('pin_tool_shift'));
    final pinField = tester.getRect(byId('pin_shift_pin'));
    expect(pinField.top, greaterThan(picker.bottom));
    // Only the card header is in between; the section notes come after the
    // tool.
    expect(pinField.top - picker.bottom, lessThan(80));
    expect(tester.getRect(find.text(l.pinOfflineNote)).top,
        greaterThan(tester.getRect(byId('pin_shift_threat')).bottom));
    expect(tester.getRect(byId('pin_show_legacy')).top,
        greaterThan(tester.getRect(find.text(l.pinOfflineNote)).bottom));

    // The other tools keep the notes above them.
    await tester.tap(byId('pin_tool_yubikey'));
    await tester.pump();
    expect(tester.getRect(find.text(l.pinOfflineNote)).bottom,
        lessThan(tester.getRect(byId('yk_view')).top));
  });

  testWidgets('the seed cached by PIN 24 is shown and wipeable elsewhere',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    final container = await pumpPin(tester, tool: PinTool.pin24);
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
    final container = await pumpPin(tester, tool: PinTool.pin24);
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
    await pumpPin(tester, tool: PinTool.pin24);
    final l = l10n(tester);

    await tester.tap(byId('pin24_selftest'));
    await tester.pump();
    await tester.pump();
    expect(find.text(l.pin24SelfTestOk(10, 10)), findsOneWidget);
  });

  // Trace C0.5: a system file picker backgrounds the app on Android; the
  // PIN tab must not wipe what the user is working on while it is open.
  testWidgets('a system picker suppresses the background wipe, only while open',
      (tester) async {
    useTallSurface(tester);
    resetLifecycleOnTearDown(tester);
    mockPrivacyChannel(tester);
    final container = await pumpPin(tester, tool: PinTool.pin24);
    await enterPin24(tester, seed: abandon12, nickname: 'visa');

    final picked = Completer<String?>();
    final picking = runExternalPicker(() => picked.future);
    expect(externalPickerActive, isTrue);
    setLifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    setLifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    expect(fieldText(tester, 'pin24_seed'), abandon12);
    expect(container.read(pinSeedProvider).hasSeed, isTrue);
    expect(displayedPin(tester), '0853');

    picked.complete(null);
    await picking;
    expect(externalPickerActive, isFalse);
    setLifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    setLifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    expect(fieldText(tester, 'pin24_seed'), isEmpty);
    expect(container.read(pinSeedProvider).hasSeed, isFalse);
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
