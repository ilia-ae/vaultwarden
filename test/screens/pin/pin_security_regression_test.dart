// Regression tests for the C8 security review of the PIN tab. Each test is
// one of the review's probes, turned around to assert the safe behaviour.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';

import 'pin_harness.dart';

const _masterA = 'SYNTHETIC-TEST-MASTER-KEY-A-0123456789abcdef';

Future<void> _tap(WidgetTester tester, String id) async {
  await tester.ensureVisible(byId(id));
  await tester.pump();
  await tester.tap(byId(id));
}

Future<void> _ctrl(WidgetTester tester, LogicalKeyboardKey key,
    {bool shift = false}) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

/// Focuses the field [id] again (as a user tapping into it would) and tries
/// Undo and Redo on the keyboard.
Future<void> _refocusAndUndo(WidgetTester tester, String id) async {
  await tester.showKeyboard(fieldById(id));
  await tester.pump();
  await _ctrl(tester, LogicalKeyboardKey.keyZ);
  await tester.pump(const Duration(seconds: 1));
  await _ctrl(tester, LogicalKeyboardKey.keyZ, shift: true);
  await _ctrl(tester, LogicalKeyboardKey.keyY);
  await tester.pump(const Duration(seconds: 1));
}

/// What the engine sends for the iOS system Undo (shake, three fingers).
Future<void> _platformUndo(WidgetTester tester) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/undomanager',
    const JSONMethodCodec().encodeMethodCall(
        const MethodCall('UndoManagerClient.handleUndo', <Object>['undo'])),
    (_) {},
  );
  await tester.pump();
}

void main() {
  setUp(setPinPrefs);

  group('security #1: a wipe cannot be undone', () {
    testWidgets('Ctrl+Z after 🚨 Wipe all brings nothing back', (tester) async {
      useTallSurface(tester);
      final log = mockPrivacyChannel(tester);
      final container = await pumpPin(tester, tool: PinTool.pin24);
      await tester.enterText(fieldById('pin24_nickname'), 'visa');
      await tester.pump();
      await tester.enterText(fieldById('pin24_seed'), abandon12);
      await settleDerivation(tester);
      await tester.pump(const Duration(seconds: 1)); // undo throttle (500 ms)
      expect(displayedPin(tester), '0853');

      await _tap(tester, 'pin24_wipe_all');
      await tester.pumpAndSettle();
      await tester.tap(byId('pin24_wipe_all_confirm'));
      await tester.pumpAndSettle();
      expect(container.read(pinSeedProvider).hasSeed, isFalse);
      // The wiped field lost focus (and with it the keyboard).
      expect(
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorStateOfType<EditableTextState>(),
          isNull);

      await _ctrl(tester, LogicalKeyboardKey.keyZ);
      await _refocusAndUndo(tester, 'pin24_seed');
      expect(fieldText(tester, 'pin24_seed'), isEmpty);
      await _refocusAndUndo(tester, 'pin24_nickname');
      expect(fieldText(tester, 'pin24_nickname'), isEmpty);
      expect(byId('pin24_output'), findsNothing);
      expect(log.named('clearClipboardIfOurs'), isNotEmpty);
    });

    testWidgets('Ctrl+Z after the 120 s inactivity wipe brings nothing back',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      final container = await pumpPin(tester, tool: PinTool.pin24);
      await tester.enterText(fieldById('pin24_nickname'), 'visa');
      await tester.pump();
      await tester.enterText(fieldById('pin24_seed'), abandon12);
      await settleDerivation(tester);
      await tester.pump(const Duration(seconds: 1));

      await tester.pump(const Duration(seconds: 121)); // unattended phone
      expect(fieldText(tester, 'pin24_seed'), isEmpty);
      expect(container.read(pinSeedProvider).hasSeed, isFalse);

      await _ctrl(tester, LogicalKeyboardKey.keyZ);
      await _refocusAndUndo(tester, 'pin24_seed');
      expect(fieldText(tester, 'pin24_seed'), isEmpty);
      // Retyping the nickname cannot re-derive anything.
      await tester.enterText(fieldById('pin24_nickname'), 'visa');
      await settleDerivation(tester);
      expect(byId('pin24_output'), findsNothing);
    });

    testWidgets('iOS system undo after 🧹 brings nothing back', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        useTallSurface(tester);
        mockPrivacyChannel(tester);
        await pumpPin(tester, tool: PinTool.pin24);
        await tester.enterText(fieldById('pin24_nickname'), 'visa');
        await tester.pump();
        await tester.enterText(fieldById('pin24_seed'), abandon12);
        await settleDerivation(tester);
        await tester.pump(const Duration(seconds: 1));
        await _tap(tester, 'pin24_wipe_seed');
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(fieldText(tester, 'pin24_seed'), isEmpty);

        await _platformUndo(tester);
        expect(fieldText(tester, 'pin24_seed'), isEmpty);
        // Even with the (rebuilt) field focused again.
        await tester.showKeyboard(fieldById('pin24_seed'));
        await tester.pump();
        await _platformUndo(tester);
        expect(fieldText(tester, 'pin24_seed'), isEmpty);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('YubiKey master key and PIN Shift vector stay wiped (Ctrl+Z)',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester);
      await _tap(tester, 'pin_tool_yubikey');
      await tester.pump();
      await _tap(tester, 'yk_source_master');
      await tester.pump();
      await tester.enterText(fieldById('yk_serials'), '12345678');
      await tester.pump();
      await tester.enterText(fieldById('yk_master_key'), _masterA);
      await settleDerivation(tester);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 121));
      expect(fieldText(tester, 'yk_master_key'), isEmpty);
      await _ctrl(tester, LogicalKeyboardKey.keyZ);
      await _refocusAndUndo(tester, 'yk_master_key');
      expect(fieldText(tester, 'yk_master_key'), isEmpty);

      await _tap(tester, 'pin_tool_shift');
      await tester.pump();
      await tester.enterText(fieldById('pin_shift_pin'), '1234');
      await tester.pump();
      await tester.enterText(fieldById('pin_shift_vector'), '3719');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 121));
      expect(fieldText(tester, 'pin_shift_vector'), isEmpty);
      await _ctrl(tester, LogicalKeyboardKey.keyZ);
      await _refocusAndUndo(tester, 'pin_shift_vector');
      expect(fieldText(tester, 'pin_shift_vector'), isEmpty);

      // Clear rebuilds the fields too.
      await tester.enterText(fieldById('pin_shift_vector'), '3719');
      await tester.pump(const Duration(seconds: 1));
      await _tap(tester, 'pin_shift_clear');
      await tester.pump();
      await _refocusAndUndo(tester, 'pin_shift_vector');
      expect(fieldText(tester, 'pin_shift_vector'), isEmpty);
    });
  });

  group('security #2: no CSV after a wipe', () {
    Future<void> openCsvConfirm(WidgetTester tester, String source) async {
      await _tap(tester, 'pin_tool_yubikey');
      await tester.pump();
      await _tap(tester, source);
      await tester.pump();
      if (source == 'yk_source_master') {
        await tester.enterText(fieldById('yk_master_key'), _masterA);
        await tester.pump();
      }
      await tester.enterText(fieldById('yk_serials'), '12345678');
      await settleDerivation(tester);
      expect(byId('yk_row_12345678_00'), findsOneWidget);
      await _tap(tester, 'yk_copy_csv');
      await tester.pumpAndSettle();
      expect(byId('yk_csv_confirm'), findsOneWidget);
    }

    testWidgets('the inactivity wipe closes the confirmation; nothing copied',
        (tester) async {
      useTallSurface(tester);
      final channel = mockPrivacyChannel(tester);
      final container = await pumpPin(tester);
      await openCsvConfirm(tester, 'yk_source_master');

      await tester.pump(const Duration(seconds: 121));
      await tester.pumpAndSettle();
      expect(byId('yk_row_12345678_00'), findsNothing);
      expect(container.read(pinSessionProvider).hasContent, isFalse);
      expect(byId('yk_csv_confirm'), findsNothing, reason: 'dialog closed');
      expect(channel.named('copySensitive'), isEmpty);
    });

    testWidgets('a background wipe closes it too (random source)',
        (tester) async {
      useTallSurface(tester);
      resetLifecycleOnTearDown(tester);
      final channel = mockPrivacyChannel(tester);
      await pumpPin(tester);
      await openCsvConfirm(tester, 'yk_source_random');

      setLifecycle(tester, AppLifecycleState.paused);
      await tester.pump();
      setLifecycle(tester, AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(byId('yk_row_12345678_00'), findsNothing);
      expect(byId('yk_csv_confirm'), findsNothing);
      expect(channel.named('copySensitive'), isEmpty);
    });

    testWidgets('confirming copies the CSV of the values shown then',
        (tester) async {
      useTallSurface(tester);
      final channel = mockPrivacyChannel(tester);
      await pumpPin(tester);
      await openCsvConfirm(tester, 'yk_source_master');
      await tester.tap(byId('yk_csv_confirm'));
      await tester.pumpAndSettle();
      final text = (channel.named('copySensitive').single.arguments
          as Map)['text'] as String;
      expect(text, startsWith('folder,name,field,value\n'));
      expect(text, contains('yk-fleet,12345678,00 '));
    });
  });

  group('security #3/#5: clipboard after wipes', () {
    testWidgets(
        '🧹 clears a pasted seed; the reminder survives a background '
        'wipe', (tester) async {
      useTallSurface(tester);
      resetLifecycleOnTearDown(tester);
      final log = mockPrivacyChannel(tester);
      final container = await pumpPin(tester, tool: PinTool.pin24);
      // One big edit = a paste the field could not see (iOS native menu).
      await tester.enterText(fieldById('pin24_seed'), abandon12);
      await tester.pump();
      expect(byId('pin24_clear_clipboard'), findsOneWidget);

      // Background: nothing is cleared (the user may be switching apps on
      // purpose) and the reminder is back on return.
      setLifecycle(tester, AppLifecycleState.paused);
      await tester.pump();
      setLifecycle(tester, AppLifecycleState.resumed);
      await tester.pump();
      expect(fieldText(tester, 'pin24_seed'), isEmpty);
      expect(byId('pin24_clear_clipboard'), findsOneWidget);
      expect(log.named('clearClipboard'), isEmpty);
      expect(log.named('clearClipboardIfOurs'), isEmpty);
      expect(
          container.read(pinSessionProvider).clipboardHoldsPaste.value, isTrue);

      // 🧹 (user-initiated): the pasted secret leaves the clipboard.
      await _tap(tester, 'pin24_wipe_seed');
      await tester.pump();
      await tester.pump();
      expect(log.named('clearClipboardIfOurs'), hasLength(1));
      expect(log.named('clearClipboard'), hasLength(1));
      expect(byId('pin24_clear_clipboard'), findsNothing);
    });

    testWidgets('the reminder follows the user to other tools', (tester) async {
      useTallSurface(tester);
      final log = mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      await tester.enterText(fieldById('pin24_seed'), abandon12);
      await tester.pump();
      await _tap(tester, 'pin_tool_shift');
      await tester.pump();
      expect(byId('pin_clear_clipboard'), findsOneWidget);
      // Clear in PIN Shift is user-initiated too.
      await _tap(tester, 'pin_shift_clear');
      await tester.pump();
      await tester.pump();
      expect(log.named('clearClipboard'), hasLength(1));
      expect(byId('pin_clear_clipboard'), findsNothing);
    });

    testWidgets('🚨 Wipe all takes a copied PIN back off the clipboard',
        (tester) async {
      useTallSurface(tester);
      final log = mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      await tester.enterText(fieldById('pin24_nickname'), 'visa');
      await tester.pump();
      // Typed key by key, not pasted: only our own copy is on the clipboard.
      for (final ch in abandon12.split('')) {
        await tester.enterText(
            fieldById('pin24_seed'), fieldText(tester, 'pin24_seed') + ch);
      }
      await settleDerivation(tester);
      expect(byId('pin24_clear_clipboard'), findsNothing);
      await tester.tap(byId('pin24_output'));
      await tester.pump();
      expect(log.named('copySensitive'), hasLength(1));
      await tester.pump(const Duration(seconds: 2));

      await _tap(tester, 'pin24_wipe_all');
      await tester.pumpAndSettle();
      await tester.tap(byId('pin24_wipe_all_confirm'));
      await tester.pumpAndSettle();
      expect(log.named('clearClipboardIfOurs'), hasLength(1));
      expect(log.named('clearClipboard'), isEmpty, reason: 'nothing pasted');
    });

    testWidgets(
        'the screenshot Wipe clears ours; inactivity only ours; '
        'background nothing', (tester) async {
      useTallSurface(tester);
      resetLifecycleOnTearDown(tester);
      final log = mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);
      await enterPin24(tester, seed: abandon12, nickname: 'visa');

      setLifecycle(tester, AppLifecycleState.paused);
      await tester.pump();
      setLifecycle(tester, AppLifecycleState.resumed);
      await tester.pump();
      expect(log.named('clearClipboardIfOurs'), isEmpty);
      // Let the "wiped" SnackBar run its course.
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      await tester.pump(const Duration(seconds: 121));
      expect(log.named('clearClipboardIfOurs'), hasLength(1));
      expect(log.named('clearClipboard'), isEmpty,
          reason: 'a pasted seed keeps its reminder after inactivity');

      await sendPrivacyEvent(tester, 'screenshot');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SnackBarAction, l.pinWipeAction));
      await tester.pump();
      await tester.pump();
      expect(log.named('clearClipboardIfOurs'), hasLength(2));
      expect(log.named('clearClipboard'), hasLength(1),
          reason: 'the screenshot Wipe is user-initiated');
    });
  });

  group('security #6: a revealed secret cannot reach the plain clipboard', () {
    testWidgets('Ctrl+A, Ctrl+C / Ctrl+X on a revealed PIN Shift vector',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      final platformCalls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        platformCalls.add(call);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await pumpPin(tester);
      await _tap(tester, 'pin_tool_shift');
      await tester.pump();
      await tester.enterText(fieldById('pin_shift_vector'), '3719');
      await tester.pump();
      await _tap(tester, 'pin_shift_vector_eye');
      await tester.pump();
      expect(tester.widget<EditableText>(fieldById('pin_shift_vector')),
          isA<EditableText>().having((e) => e.obscureText, 'obscured', false));
      await tester.showKeyboard(fieldById('pin_shift_vector'));
      await _ctrl(tester, LogicalKeyboardKey.keyA);
      await _ctrl(tester, LogicalKeyboardKey.keyC);
      await _ctrl(tester, LogicalKeyboardKey.keyX);
      expect(
          platformCalls.where((c) => c.method == 'Clipboard.setData'), isEmpty);
      expect(fieldText(tester, 'pin_shift_vector'), '3719', reason: 'no cut');
    });
  });

  group('security #7/#8: masked inputs leak nothing', () {
    testWidgets('no weak-vector notice while base PIN and vector are hidden',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester);
      await _tap(tester, 'pin_tool_shift');
      await tester.pump();
      // Weak vectors of the default length (8): a result is shown, the
      // notices are not.
      for (final vector in ['55555555', '00000000', '12345678']) {
        await tester.enterText(fieldById('pin_shift_pin'), '12345678');
        await tester.enterText(fieldById('pin_shift_vector'), vector);
        await tester.pump();
        expect(byId('pin_shift_roundtrip'), findsOneWidget, reason: vector);
        expect(byId('pin_shift_input_row'), findsNothing);
        for (final id in [
          'pin_shift_weak_zero',
          'pin_shift_weak_fives',
          'pin_shift_weak_equal',
        ]) {
          expect(byId(id), findsNothing, reason: '$vector $id');
        }
      }
      // Screen readers do not get the hidden output's digits either.
      final handle = tester.ensureSemantics();
      expect(find.bySemanticsLabel(RegExp(r'\d \d \d \d')), findsNothing);
      handle.dispose();
    });

    testWidgets('the masked master key shows no exact length', (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester);
      final l = l10n(tester);
      await _tap(tester, 'pin_tool_yubikey');
      await tester.pump();
      await _tap(tester, 'yk_source_master');
      await tester.pump();
      await tester.enterText(
          fieldById('yk_master_key'), 'correct horse battery staple x9 !');
      await tester.pump();
      String status() => tester
          .widgetList<Text>(find.descendant(
              of: byId('yk_master_bytes'), matching: find.byType(Text)))
          .map((t) => t.data ?? '')
          .join();
      // 33 bytes: only "long enough" (the old line read "33 bytes").
      expect(status(), l.pinYkMasterOk(32));
      expect(status(), isNot(contains('33')));

      await tester.enterText(fieldById('yk_master_key'), 'short key 17 byte');
      await tester.pump();
      expect(status(), l.pinYkMasterShort(32));
      expect(status(), isNot(contains('17')));
    });
  });
}
