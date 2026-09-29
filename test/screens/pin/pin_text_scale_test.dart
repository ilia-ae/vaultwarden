// UX #2, #9, #13, #19: the PIN tools at text scale ×2.0 on a 320 pt phone
// (and ×1.3), in en/ru/ar: no overflow, no clipped text, no labels drawn over
// the values, no text squeezed into a sliver next to a button.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/screens/pin/pin_section.dart';
import 'package:vault_approver/screens/pin/pin_widgets.dart';

import 'pin_harness.dart';

const _masterA = 'SYNTHETIC-TEST-MASTER-KEY-A-0123456789abcdef';

Future<void> _tap(WidgetTester tester, String id) async {
  await tester.ensureVisible(byId(id));
  await tester.pump();
  await tester.tap(byId(id));
  await tester.pump();
}

Future<void> _pumpScaled(
  WidgetTester tester, {
  required double width,
  required double scale,
  required String locale,
}) async {
  tester.view.physicalSize = Size(width, 40000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await pumpPin(
    tester,
    locale: Locale(locale),
    child: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: const PinSection(),
      ),
    ),
  );
}

/// Every problem the C8 layout matrix looked for, in the current tree.
List<String> _layoutProblems(WidgetTester tester, String state) {
  final problems = <String>[];
  final paragraphs = <RenderParagraph>[];
  void visit(RenderObject o) {
    if (o is RenderParagraph) paragraphs.add(o);
    o.visitChildren(visit);
  }

  visit(tester.renderObject(find.byType(PinSection)));
  String describe(RenderParagraph rp) {
    final t = rp.text.toPlainText().replaceAll('\n', ' ');
    return t.length > 40 ? '${t.substring(0, 40)}…' : t;
  }

  final rects = <RenderParagraph, Rect>{};
  for (final rp in paragraphs) {
    if (!rp.hasSize || !rp.attached) continue;
    rects[rp] = rp.localToGlobal(Offset.zero) & rp.size;
    if (rp.maxLines != null) continue;
    final natural =
        rp.getDryLayout(BoxConstraints(maxWidth: rp.constraints.maxWidth));
    if (natural.height > rp.size.height + 1 ||
        natural.width > rp.size.width + 1) {
      problems.add('[$state] CLIPPED "${describe(rp)}" '
          'natural=${natural.width.round()}x${natural.height.round()} '
          'box=${rp.size.width.round()}x${rp.size.height.round()}');
    }
    final oneLine = rp.getDryLayout(const BoxConstraints());
    if (rp.size.width < 48 &&
        oneLine.width > 4 * rp.size.width &&
        oneLine.width > 120) {
      problems.add('[$state] SQUASHED "${describe(rp)}" '
          'width=${rp.size.width.round()}');
    }
  }
  // 9 pt labels (word index, walk position/visits) never cover a value.
  for (final e in rects.entries) {
    if (e.key.text.style?.fontSize != 9) continue;
    for (final o in rects.entries) {
      if (identical(o.key, e.key) || o.key.text.style?.fontSize == 9) continue;
      final i = e.value.intersect(o.value);
      if (i.width > 1 && i.height > 1 && o.value.width < 80) {
        problems.add('[$state] OVERLAP "${describe(e.key)}" over '
            '"${describe(o.key)}"');
      }
    }
  }
  return problems;
}

Future<List<String>> _walkAllTools(WidgetTester tester) async {
  final problems = <String>[];
  Future<void> check(String state) async {
    await tester.pump();
    final e = tester.takeException();
    if (e != null) problems.add('[$state] EXCEPTION $e');
    problems.addAll(_layoutProblems(tester, state));
  }

  // PIN 24: pasted seed (clipboard reminder), revealed words, result.
  await tester.enterText(fieldById('pin24_seed'), speculos24);
  await tester.pump();
  await _tap(tester, 'pin24_show_words');
  await tester.enterText(fieldById('pin24_nickname'), 'gmail');
  await settleDerivation(tester);
  await _tap(tester, 'pin24_len_8');
  await settleDerivation(tester);
  await _tap(tester, 'pin24_reveal_pin');
  await _tap(tester, 'pin24_show_full');
  await check('pin24-result');
  await _tap(tester, 'pin24_mode_password');
  await settleDerivation(tester);
  await check('pin24-password');

  // YubiKey: short master key pasted (reminder + status), random values.
  await _tap(tester, 'pin_tool_yubikey');
  await _tap(tester, 'yk_source_master');
  await tester.enterText(fieldById('yk_master_key'), 'abcdefghijklmnopqrst');
  await tester.enterText(fieldById('yk_serials'), '12345678, 1234567890123');
  await settleDerivation(tester);
  await check('yk-master-short');
  await tester.enterText(fieldById('yk_master_key'), _masterA);
  await settleDerivation(tester);
  await _tap(tester, 'yk_reveal_12345678_41');
  await _tap(tester, 'yk_reveal_12345678_24');
  await check('yk-values');

  // PIN Shift: 16 digits, revealed.
  await _tap(tester, 'pin_tool_shift');
  await tester.pumpAndSettle();
  for (var i = 4; i < 16; i++) {
    await _tap(tester, 'pin_shift_len_inc');
  }
  await tester.enterText(fieldById('pin_shift_pin'), '1234567890123456');
  await tester.enterText(fieldById('pin_shift_vector'), '3719371937193719');
  await tester.pump();
  await _tap(tester, 'pin_shift_reveal');
  await check('shift-16-revealed');

  // Legacy: the walk.
  await _tap(tester, 'pin_show_legacy');
  await _tap(tester, 'pin_tool_legacy');
  await tester.enterText(fieldById('legacy_mask_mask'), '55555555');
  await tester.enterText(
      fieldById('legacy_mask_input'), 'ABCDEFGHIJKLMNOPQRST');
  await tester.pump();
  await _tap(tester, 'legacy_mask_reveal');
  await check('legacy-revealed');
  return problems;
}

void main() {
  setUp(setPinPrefs);

  for (final (locale, width, scale) in [
    ('en', 320.0, 2.0),
    ('ru', 320.0, 2.0),
    ('ar', 320.0, 2.0),
    ('ru', 320.0, 1.3),
    ('en', 360.0, 1.0),
  ]) {
    testWidgets(
        '$locale ${width.round()} pt ×$scale: no overflow, clipping, '
        'overlap or squeeze', (tester) async {
      mockPrivacyChannel(tester);
      await _pumpScaled(tester, width: width, scale: scale, locale: locale);
      final problems = await _walkAllTools(tester);
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }

  testWidgets('UX #19: an 8-digit PIN fits one line on a 360 pt phone',
      (tester) async {
    mockPrivacyChannel(tester);
    await _pumpScaled(tester, width: 360, scale: 1.0, locale: 'en');
    await tester.tap(byId('pin24_len_8'));
    await enterPin24(tester, seed: abandon12, nickname: 'visa');
    final digits = find.descendant(
        of: find.byType(PinDigitCells), matching: find.byType(Text));
    expect(digits, findsNWidgets(8));
    final tops = {
      for (var i = 0; i < 8; i++) tester.getTopLeft(digits.at(i)).dy.round(),
    };
    expect(tops, hasLength(1), reason: 'all cells on one line: $tops');
    expect(displayedPin(tester), hasLength(8));
  });

  testWidgets('UX #9: digit cells grow with the text size', (tester) async {
    mockPrivacyChannel(tester);
    await _pumpScaled(tester, width: 320, scale: 2.0, locale: 'en');
    await enterPin24(tester, seed: abandon12, nickname: 'visa');
    final text = find
        .descendant(of: byId('pin24_output'), matching: find.text('0'))
        .first;
    final cell =
        find.ancestor(of: text, matching: find.byType(Container)).first;
    expect(tester.getSize(cell).height,
        greaterThanOrEqualTo(tester.getSize(text).height));
  });
}
