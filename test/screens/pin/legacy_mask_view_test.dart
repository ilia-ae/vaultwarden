import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/pin_tools/mask_pin.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';
import 'package:vault_approver/screens/pin/pin_widgets.dart';

import 'pin_harness.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/pin_tools/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

Future<void> _openLegacy(WidgetTester tester) async {
  await tester.tap(byId('pin_show_legacy'));
  await tester.pump();
  await tester.tap(byId('pin_tool_legacy'));
  await tester.pump();
}

Future<void> _enter(WidgetTester tester, String mask, String input) async {
  await tester.enterText(fieldById('legacy_mask_mask'), mask);
  await tester.pump();
  await tester.enterText(fieldById('legacy_mask_input'), input);
  await tester.pump();
}

/// The 8 output characters (the dash between the groups is not text).
String _output(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(
        of: byId('legacy_mask_output'), matching: find.byType(Text)))
    .map((t) => t.data ?? '')
    .join();

Finder _visibleText(String needle) => find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').contains(needle),
      description: 'Text containing "$needle"',
    );

void main() {
  setUp(setPinPrefs);

  testWidgets('hidden unless "Show legacy tools" is on; marked legacy',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    final l = l10n(tester);

    expect(byId('pin_tool_legacy'), findsNothing);
    expect(byId('legacy_mask_view'), findsNothing);

    await _openLegacy(tester);
    expect(byId('legacy_mask_view'), findsOneWidget);
    expect(find.text(l.pinLegacyBadge), findsOneWidget);
    expect(find.text(l.pinLegacyBanner), findsOneWidget);
    expect(find.text(l.pinLegacyNotPorted), findsOneWidget);
  });

  testWidgets('every public vector (pass_pin.json)', (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openLegacy(tester);
    final l = l10n(tester);

    final vectors = _fixture('pass_pin.json')['vectors'] as List;
    expect(vectors, hasLength(51));
    for (final v in vectors) {
      final mask = v['mask'] as String;
      await _enter(tester, mask, v['input'] as String);
      expect(_output(tester), v['expected'], reason: v['id'] as String);
      final revisits = (v['revisit_steps_0based'] as List).length;
      expect(
        find.text(l.pinLegacyRevisitWarning(revisits)),
        revisits == 0 ? findsNothing : findsOneWidget,
        reason: v['id'] as String,
      );
    }
  });

  testWidgets(
      '👁 shows the walk; revisits are warned (also runs summing to 60)',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openLegacy(tester);
    final l = l10n(tester);

    await _enter(tester, '24681357', 'ABCDEFGHIJKLMNOPQRST');
    expect(_output(tester), 'BFLTADIP');
    expect(byId('legacy_mask_positions'), findsNothing);
    expect(byId('legacy_mask_revisit_warning'), findsNothing);
    await tester.tap(byId('legacy_mask_reveal'));
    await tester.pump();
    expect(
        find.text(l.pinLegacyVisited(ltrIsolate('2, 6, 12, 20, 1, 4, 9, 16'))),
        findsOneWidget);
    expect(byId('legacy_mask_walk'), findsOneWidget);

    await _enter(tester, '55555555', 'ABCDEFGHIJKLMNOPQRST');
    expect(_output(tester), 'EJOT0000');
    expect(find.text(l.pinLegacyRevisitWarning(4)), findsOneWidget);
    expect(find.text(l.pinLegacyRevisitSteps(ltrIsolate('5, 6, 7, 8'))),
        findsOneWidget);

    // Steps 2..8 of 19999996 sum to 60 at the last step (critic #3).
    await _enter(tester, '19999996', 'ABCDEFGHIJKLMNOPQRST');
    expect(_output(tester), 'AJSHQFO0');
    expect(find.text(l.pinLegacyRevisitWarning(1)), findsOneWidget);
    expect(find.text(l.pinLegacyRevisitSteps(ltrIsolate('8'))), findsOneWidget);

    // Without 👁 only the count is shown.
    await tester.tap(byId('legacy_mask_reveal'));
    await tester.pump();
    expect(find.text(l.pinLegacyRevisitWarning(1)), findsOneWidget);
    expect(byId('legacy_mask_revisit_steps'), findsNothing);
    expect(byId('legacy_mask_positions'), findsNothing);
  });

  testWidgets('MaskPinException codes → localized text, no input echoed',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openLegacy(tester);
    final l = l10n(tester);
    const twenty = 'ABCDEFGHIJKLMNOPQRST';

    await _enter(tester, '1234567', twenty);
    expect(byId('legacy_mask_mask_error'), findsNothing);
    expect(find.text(l.pinLegacyIncomplete), findsOneWidget);

    await _enter(tester, '123456789', twenty);
    expect(find.text(l.pinLegacyErrMaskFormat), findsOneWidget);
    expect(find.text(l.pinFixErrorsAbove), findsOneWidget);

    await _enter(tester, 'Ж2345678', twenty);
    expect(find.text(l.pinLegacyErrMaskFormat), findsOneWidget);
    expect(_visibleText('Ж'), findsNothing);

    await _enter(tester, '12345670', twenty);
    expect(find.text(l.pinLegacyErrMaskValueRange(8)), findsOneWidget);
    // The script's 1–20 range cannot be typed: say that 0 is the problem.
    expect(find.text(l.pinLegacyMaskZeroHint), findsOneWidget);
    expect(l.pinLegacyMaskHelp, contains('1–9'));

    // ASCII only, on purpose: Arabic-Indic digits get a hint.
    await _enter(tester, '٢٤٦٨١٣٥٧', twenty);
    expect(find.text(l.pinLegacyErrMaskFormat), findsOneWidget);
    expect(find.text(l.pinLegacyMaskAsciiOnly), findsOneWidget);

    // Input length counts code points and ignores whitespace.
    await _enter(tester, '24681357', 'ABC DEF');
    expect(find.text('6 / 20'), findsOneWidget);
    expect(find.text(l.pinLegacyIncomplete), findsOneWidget);
    await _enter(tester, '24681357', '${twenty}U');
    expect(find.text('21 / 20'), findsOneWidget);
    expect(find.text(l.pinLegacyErrInputLength), findsOneWidget);
    // Ten emoji are 20 UTF-16 units but only 10 characters.
    await _enter(tester, '24681357', '😀' * 10);
    expect(find.text('10 / 20'), findsOneWidget);
  });

  testWidgets('Russian messages are the original Python texts', (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester, locale: const Locale('ru'));
    await _openLegacy(tester);

    await _enter(tester, '123456789', 'ABCDEFGHIJKLMNOPQRST');
    expect(find.text(const MaskPinException.maskFormat().messageRu),
        findsOneWidget);
    await _enter(tester, '12345670', 'ABCDEFGHIJKLMNOPQRST');
    expect(find.text(MaskPinException.maskValueRange(8).messageRu),
        findsOneWidget);
    await _enter(tester, '24681357', 'ABCDEFGHIJKLMNOPQRSTU');
    expect(find.text(const MaskPinException.inputLength().messageRu),
        findsOneWidget);
  });

  testWidgets('wipe and Clear empty both fields and hide everything',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    final container = await pumpPin(tester);
    await _openLegacy(tester);

    await _enter(tester, '24681357', 'ABCDEFGHIJKLMNOPQRST');
    await tester.tap(byId('legacy_mask_mask_eye'));
    await tester.tap(byId('legacy_mask_reveal'));
    await tester.pump();
    expect(
        tester.widget<EditableText>(fieldById('legacy_mask_mask')).obscureText,
        isFalse);
    expect(container.read(pinSessionProvider).hasContent, isTrue);

    container.read(pinSessionProvider).wipe(reason: PinWipeReason.inactivity);
    await tester.pump();
    expect(fieldText(tester, 'legacy_mask_mask'), isEmpty);
    expect(fieldText(tester, 'legacy_mask_input'), isEmpty);
    expect(
        tester.widget<EditableText>(fieldById('legacy_mask_mask')).obscureText,
        isTrue);
    expect(byId('legacy_mask_positions'), findsNothing);
    expect(container.read(pinSessionProvider).hasContent, isFalse);

    await _enter(tester, '24681357', 'ABCDEFGHIJKLMNOPQRST');
    await tester.tap(byId('legacy_mask_clear'));
    await tester.pump();
    expect(fieldText(tester, 'legacy_mask_mask'), isEmpty);
    expect(fieldText(tester, 'legacy_mask_input'), isEmpty);
  });
}
