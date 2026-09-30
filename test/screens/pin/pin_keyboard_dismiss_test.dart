// iOS number pads have no return key: the PIN tab closes the keyboard on a
// tap outside the fields, on a drag of the list and with a Done pill over a
// return-less keyboard. Closing the keyboard only unfocuses — nothing is
// wiped.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';
import 'package:vault_approver/widgets/keyboard_dismiss.dart';

import 'pin_harness.dart';

/// An 874-pt iPhone in portrait.
void _usePhone(WidgetTester tester) {
  tester.view.physicalSize = const Size(1206, 2622);
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
  addTearDown(tester.view.reset);
}

/// Shows (or hides) a 336-pt software keyboard, like the platform does.
Future<void> _keyboard(WidgetTester tester, {required bool up}) async {
  tester.view.viewInsets =
      up ? const FakeViewPadding(bottom: 336 * 3) : FakeViewPadding.zero;
  await tester.pump();
}

Future<void> _openShift(WidgetTester tester) async {
  await tester.tap(byId('pin_tool_shift'));
  await tester.pump();
}

Future<void> _openLegacy(WidgetTester tester) async {
  await tester.ensureVisible(byId('pin_show_legacy'));
  await tester.tap(byId('pin_show_legacy'));
  await tester.pump();
  await tester.ensureVisible(byId('pin_tool_legacy'));
  await tester.tap(byId('pin_tool_legacy'));
  await tester.pump();
}

bool _focused(WidgetTester tester, String id) =>
    tester.widget<EditableText>(fieldById(id)).focusNode.hasFocus;

final _done = byId('btn_keyboard_done');

void main() {
  setUp(setPinPrefs);

  test('keyboards without a return key', () {
    expect(keyboardLacksReturnKey(TextInputType.number), isTrue);
    expect(
      keyboardLacksReturnKey(
          const TextInputType.numberWithOptions(decimal: true)),
      isTrue,
    );
    expect(keyboardLacksReturnKey(TextInputType.phone), isTrue);
    expect(
      keyboardLacksReturnKey(
          const TextInputType.numberWithOptions(signed: true)),
      isFalse,
      reason: 'numbers-and-punctuation has a return key',
    );
    expect(keyboardLacksReturnKey(TextInputType.text), isFalse);
    expect(keyboardLacksReturnKey(TextInputType.visiblePassword), isFalse);
    expect(keyboardLacksReturnKey(null), isFalse);
  });

  testWidgets(
      'a tap outside the fields closes the keyboard and keeps the value; '
      'buttons and other fields keep their taps', (tester) async {
    _usePhone(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openShift(tester);
    final l = l10n(tester);

    await tester.showKeyboard(fieldById('pin_shift_pin'));
    await tester.enterText(fieldById('pin_shift_pin'), '1234');
    await tester.pump();
    expect(_focused(tester, 'pin_shift_pin'), isTrue);

    // A button takes its own tap: the length changes, the field keeps focus.
    await tester.ensureVisible(byId('pin_shift_len_inc'));
    await tester.tap(byId('pin_shift_len_inc'));
    await tester.pump();
    expect(_focused(tester, 'pin_shift_pin'), isTrue);

    // Another field takes the focus.
    await tester.ensureVisible(fieldById('pin_shift_vector'));
    await tester.tap(fieldById('pin_shift_vector'));
    await tester.pump();
    expect(_focused(tester, 'pin_shift_vector'), isTrue);

    // Plain text is "outside": the keyboard goes, nothing is wiped.
    await tester.ensureVisible(find.text(l.pinOfflineNote));
    await tester.tap(find.text(l.pinOfflineNote));
    await tester.pump();
    expect(FocusManager.instance.primaryFocus?.context?.widget,
        isNot(isA<EditableText>()));
    expect(_focused(tester, 'pin_shift_vector'), isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(fieldText(tester, 'pin_shift_pin'), '1234');
  });

  testWidgets('dragging the list closes the keyboard (onDrag)', (tester) async {
    _usePhone(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openShift(tester);

    await tester.showKeyboard(fieldById('pin_shift_vector'));
    await tester.enterText(fieldById('pin_shift_vector'), '3719');
    await tester.pump();
    expect(_focused(tester, 'pin_shift_vector'), isTrue);

    await tester.drag(
        find.byType(SingleChildScrollView).first, const Offset(0, -120));
    await tester.pump();
    expect(_focused(tester, 'pin_shift_vector'), isFalse);
    expect(fieldText(tester, 'pin_shift_vector'), '3719');
  });

  testWidgets('iOS: a Done pill over the number pad closes it (PIN Shift)',
      (tester) async {
    _usePhone(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openShift(tester);

    await tester.showKeyboard(fieldById('pin_shift_pin'));
    await tester.enterText(fieldById('pin_shift_pin'), '1234');
    await tester.pump();
    // Focused, but the software keyboard is not up (hardware keyboard).
    expect(_done, findsNothing);

    await _keyboard(tester, up: true);
    expect(_done, findsOneWidget);
    // Right above the keyboard, clear of it.
    final pill = tester.getRect(_done);
    expect(pill.bottom, lessThanOrEqualTo(874 - 336));
    expect(pill.bottom, greaterThan(874 - 336 - 20));
    // The field scrolls clear of the pill when the keyboard reveals it.
    expect(
      tester.widget<EditableText>(fieldById('pin_shift_pin')).scrollPadding,
      const EdgeInsets.fromLTRB(
          20, 20, 20, 20 + KeyboardDismissRegion.reservedHeight),
    );

    await tester.tap(_done);
    await tester.pump();
    expect(_focused(tester, 'pin_shift_pin'), isFalse);
    expect(tester.testTextInput.isVisible, isFalse);
    expect(fieldText(tester, 'pin_shift_pin'), '1234', reason: 'not wiped');
    expect(_done, findsNothing);
    await _keyboard(tester, up: false);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('iOS: the legacy mask field gets the Done pill too',
      (tester) async {
    _usePhone(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openLegacy(tester);

    await tester.ensureVisible(fieldById('legacy_mask_mask'));
    await tester.showKeyboard(fieldById('legacy_mask_mask'));
    await _keyboard(tester, up: true);
    expect(_done, findsOneWidget);
    await tester.tap(_done);
    await tester.pump();
    expect(_focused(tester, 'legacy_mask_mask'), isFalse);
    await _keyboard(tester, up: false);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('iOS: no Done pill over a keyboard that has a return key',
      (tester) async {
    _usePhone(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester, tool: PinTool.pin24);

    // PIN 24's seed and nickname fields use the text keyboard.
    await tester.ensureVisible(fieldById('pin24_nickname'));
    await tester.showKeyboard(fieldById('pin24_nickname'));
    await _keyboard(tester, up: true);
    expect(_done, findsNothing);
    await _keyboard(tester, up: false);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));

  testWidgets('Android: no Done pill (its number keyboard has one)',
      (tester) async {
    _usePhone(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openShift(tester);

    await tester.showKeyboard(fieldById('pin_shift_pin'));
    await _keyboard(tester, up: true);
    expect(_done, findsNothing);
    expect(
      tester.widget<EditableText>(fieldById('pin_shift_pin')).scrollPadding,
      const EdgeInsets.all(20),
    );
    await _keyboard(tester, up: false);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
