import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';
import 'package:vault_approver/screens/pin/pin_widgets.dart';

import 'pin_harness.dart';

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/pin_tools/fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

Future<void> _openShift(WidgetTester tester) async {
  await tester.tap(byId('pin_tool_shift'));
  await tester.pump();
}

int _length(WidgetTester tester) => int.parse(tester
    .widget<Text>(find.descendant(
        of: byId('pin_shift_len_value'), matching: find.byType(Text)))
    .data!);

Future<void> _setLength(WidgetTester tester, int length) async {
  while (_length(tester) < length) {
    await tester.tap(byId('pin_shift_len_inc'));
    await tester.pump();
  }
  while (_length(tester) > length) {
    await tester.tap(byId('pin_shift_len_dec'));
    await tester.pump();
  }
}

Future<void> _enter(WidgetTester tester, String pin, String vector) async {
  await tester.enterText(fieldById('pin_shift_pin'), pin);
  await tester.pump();
  await tester.enterText(fieldById('pin_shift_vector'), vector);
  await tester.pump();
}

/// Digits shown in the cell row with Semantics identifier [id].
String _digits(WidgetTester tester, String id) => tester
    .widgetList<Text>(
        find.descendant(of: byId(id), matching: find.byType(Text)))
    .map((t) => t.data ?? '')
    .join()
    .replaceAll(RegExp(r'[^0-9]'), '');

/// Any Text widget (not the fields) whose text contains [needle].
Finder _visibleText(String needle) => find.byWidgetPredicate(
      (w) => w is Text && (w.data ?? '').contains(needle),
      description: 'Text containing "$needle"',
    );

bool _obscured(WidgetTester tester, String id) =>
    tester.widget<EditableText>(fieldById(id)).obscureText;

void main() {
  setUp(setPinPrefs);

  testWidgets('encode 1234 + 3719 = 4943, decode back, round-trip badge',
      (tester) async {
    useTallSurface(tester);
    final channel = mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openShift(tester);
    final l = l10n(tester);

    // Not-a-cipher caption and direction-dependent labels.
    expect(find.text(l.pinShiftCaption), findsOneWidget);
    expect(find.text(l.pinShiftFieldBase), findsOneWidget);
    expect(find.text(l.pinShiftEncodeHelp), findsOneWidget);

    await _enter(tester, '1234', '3719');
    expect(_digits(tester, 'pin_shift_output'), '4943');
    expect(find.text(l.pinShiftRoundTripOk), findsOneWidget);
    expect(find.text(l.pinShiftHiddenNote), findsOneWidget);
    expect(byId('pin_shift_input_row'), findsNothing);
    expect(byId('pin_shift_vector_row'), findsNothing);

    await tester.tap(byId('pin_shift_decode'));
    await tester.pump();
    expect(find.text(l.pinShiftFieldDerived), findsOneWidget);
    expect(find.text(l.pinShiftDecodeHelp), findsOneWidget);
    await tester.enterText(fieldById('pin_shift_pin'), '4943');
    await tester.pump();
    expect(_digits(tester, 'pin_shift_output'), '1234');
    expect(find.text(l.pinShiftRoundTripOkDecode), findsOneWidget);
    expect(find.text(l.pinShiftRowOutputBase), findsOneWidget);

    // No copy: tapping the output never reaches the clipboard.
    await tester.tap(byId('pin_shift_output'), warnIfMissed: false);
    await tester.pump();
    expect(channel.named('copySensitive'), isEmpty);
  });

  testWidgets('every public vector up to 16 digits (pin_shift.json)',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openShift(tester);
    final l = l10n(tester);

    final vectors = [
      for (final v in _fixture('pin_shift.json')['vectors'] as List)
        if ((v['length'] as int) <= 16) v as Map<String, dynamic>,
    ];
    expect(vectors.length, greaterThan(70));
    var decode = false;
    for (final v in vectors) {
      final wantDecode = v['decode'] as bool;
      if (wantDecode != decode) {
        await tester
            .tap(byId(wantDecode ? 'pin_shift_decode' : 'pin_shift_encode'));
        await tester.pump();
        decode = wantDecode;
      }
      await _setLength(tester, v['length'] as int);
      await _enter(tester, v['pin'] as String, v['shift'] as String);
      expect(_digits(tester, 'pin_shift_output'), v['expected'],
          reason: v['id'] as String);
      expect(
        find.text(decode ? l.pinShiftRoundTripOkDecode : l.pinShiftRoundTripOk),
        findsOneWidget,
        reason: v['id'] as String,
      );
    }
  });

  testWidgets('10^N keyspace note matches pin_shift_ui.json for 1–16',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openShift(tester);

    final texts =
        _fixture('pin_shift_ui.json')['keyspace_text'] as Map<String, dynamic>;
    for (var n = 1; n <= 16; n++) {
      await _setLength(tester, n);
      expect(_visibleText(texts['$n'] as String), findsOneWidget,
          reason: 'length $n');
    }
    // The stepper stops at 16 and at 1.
    await tester.tap(byId('pin_shift_len_inc'));
    await tester.pump();
    expect(_length(tester), 16);
    await tester.tap(byId('pin_shift_len_4'));
    await tester.pump();
    expect(_length(tester), 4);
  });

  testWidgets('reveal shows coloured rows and the per-digit table',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openShift(tester);
    final l = l10n(tester);

    for (final table
        in _fixture('pin_shift_ui.json')['per_digit_tables'] as List) {
      final decode = table['decode'] as bool;
      await tester.tap(byId(decode ? 'pin_shift_decode' : 'pin_shift_encode'));
      await tester.pump();
      await _enter(tester, table['pin'] as String, table['shift'] as String);
      if (!tester
          .widget<Switch>(find.descendant(
              of: byId('pin_shift_reveal'), matching: find.byType(Switch)))
          .value) {
        await tester.tap(byId('pin_shift_reveal'));
        await tester.pump();
      }
      expect(_digits(tester, 'pin_shift_input_row'), table['pin']);
      expect(_digits(tester, 'pin_shift_vector_row'), table['shift']);
      expect(
          find.text(l.pinShiftRowVector(decode ? '−' : '+')), findsOneWidget);
      if (find.text(l.pinShiftColFormula).evaluate().isEmpty) {
        await tester.tap(byId('pin_shift_breakdown'));
        await tester.pumpAndSettle();
      }
      for (final row in table['rows'] as List) {
        expect(find.text(row['formula'] as String), findsWidgets,
            reason: '${table['pin']} ${row['formula']}');
      }
    }
  });

  testWidgets('errors report positions only; no silent truncation',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openShift(tester);
    final l = l10n(tester);

    await _enter(tester, '12Ж4', '3719');
    expect(find.text(l.pinShiftPinNonDigit(ltrIsolate('3'))), findsOneWidget);
    expect(find.text(l.pinFixErrorsAbove), findsOneWidget);
    expect(_visibleText('Ж'), findsNothing);
    expect(byId('pin_shift_output'), findsNothing);

    await _enter(tester, '1234', '37Жz');
    expect(find.text(l.pinShiftVectorNonDigit(ltrIsolate('3, 4'))),
        findsOneWidget);
    expect(_visibleText('Ж'), findsNothing);

    // Too long: warned, never cut.
    await _enter(tester, '123456', '3719');
    expect(find.text(l.pinShiftPinLengthWarning(6, 4)), findsOneWidget);
    expect(fieldText(tester, 'pin_shift_pin'), '123456');
    expect(find.text(l.pinShiftFillBoth(4)), findsOneWidget);

    await _enter(tester, '1234', '371');
    expect(find.text(l.pinShiftVectorLengthWarning(3, 4)), findsOneWidget);

    // Arabic-Indic and fullwidth digits are normalized: 1234 + 3719.
    await _enter(tester, '١٢٣٤', '３７１９');
    expect(_digits(tester, 'pin_shift_output'), '4943');
    expect(find.text(l.pinShiftRoundTripOk), findsOneWidget);
  });

  testWidgets('weak vectors: all zeros, equal to the base, all fives',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openShift(tester);
    // The notices describe the hidden inputs: only while revealed.
    await tester.tap(byId('pin_shift_reveal'));
    await tester.pump();

    await _enter(tester, '1234', '0000');
    expect(byId('pin_shift_weak_zero'), findsOneWidget);
    expect(byId('pin_shift_weak_equal'), findsNothing);

    await _enter(tester, '1234', '1234');
    expect(byId('pin_shift_weak_equal'), findsOneWidget);
    expect(byId('pin_shift_weak_zero'), findsNothing);

    await _enter(tester, '1234', '5555');
    expect(byId('pin_shift_weak_fives'), findsOneWidget);

    // Decode: the base is the output. 2468 − 1234 = 1234 = vector.
    await tester.tap(byId('pin_shift_decode'));
    await tester.pump();
    await _enter(tester, '2468', '1234');
    expect(_digits(tester, 'pin_shift_output'), '1234');
    expect(byId('pin_shift_weak_equal'), findsOneWidget);

    await _enter(tester, '1234', '3719');
    expect(byId('pin_shift_weak_zero'), findsNothing);
    expect(byId('pin_shift_weak_equal'), findsNothing);
    expect(byId('pin_shift_weak_fives'), findsNothing);
  });

  testWidgets('eyes, reveal and inputs reset on wipe, background and Clear',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    resetLifecycleOnTearDown(tester);
    final container = await pumpPin(tester);
    await _openShift(tester);

    await _enter(tester, '1234', '3719');
    expect(_obscured(tester, 'pin_shift_pin'), isTrue);
    expect(_obscured(tester, 'pin_shift_vector'), isTrue);
    await tester.tap(byId('pin_shift_pin_eye'));
    await tester.tap(byId('pin_shift_vector_eye'));
    await tester.tap(byId('pin_shift_reveal'));
    await tester.pump();
    expect(_obscured(tester, 'pin_shift_pin'), isFalse);
    expect(_obscured(tester, 'pin_shift_vector'), isFalse);
    expect(byId('pin_shift_input_row'), findsOneWidget);
    expect(container.read(pinSessionProvider).hasContent, isTrue);

    // A seed-only wipe (🧹 in PIN 24) leaves PIN Shift alone.
    container
        .read(pinSessionProvider)
        .wipe(scope: PinWipeScope.seed, reason: PinWipeReason.user);
    await tester.pump();
    expect(fieldText(tester, 'pin_shift_pin'), '1234');

    container.read(pinSessionProvider).wipe(reason: PinWipeReason.user);
    await tester.pump();
    expect(fieldText(tester, 'pin_shift_pin'), isEmpty);
    expect(fieldText(tester, 'pin_shift_vector'), isEmpty);
    expect(_obscured(tester, 'pin_shift_pin'), isTrue);
    expect(byId('pin_shift_input_row'), findsNothing);
    expect(container.read(pinSessionProvider).hasContent, isFalse);

    // Background wipes too.
    await _enter(tester, '1234', '3719');
    setLifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    setLifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    expect(fieldText(tester, 'pin_shift_pin'), isEmpty);

    // Clear.
    await _enter(tester, '1234', '3719');
    await tester.tap(byId('pin_shift_clear'));
    await tester.pump();
    expect(fieldText(tester, 'pin_shift_pin'), isEmpty);
    expect(fieldText(tester, 'pin_shift_vector'), isEmpty);
  });

  testWidgets('paper walkthrough and threat model are always available',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openShift(tester);
    final l = l10n(tester);

    await tester.tap(byId('pin_shift_paper'));
    await tester.pumpAndSettle();
    final paper = _fixture('pin_shift_ui.json')['paper_walkthrough_md']
        as Map<String, dynamic>;
    // The worked-example rows of the source page, without its comments.
    for (final line in [
      '  base:   1 2 3 4',
      '+ vec:    3 7 1 9',
      '  raw:    4 9 4 13',
      '  mod10:  4 9 4 3',
      '  raw:    1 2 3 -6',
      '  mod10:  1 2 3 4',
    ]) {
      expect(paper['4_encode'] as String, contains(line));
      expect(_visibleText(line), findsWidgets, reason: line);
    }
    expect(_visibleText('+ vec:   _ _ _ _'), findsOneWidget);
    expect(find.text(l.pinShiftPaperRules(l.pinShiftDirectionEncode)),
        findsOneWidget);

    await tester.tap(byId('pin_shift_len_8'));
    await tester.pump();
    expect(_visibleText('+ vec:   _ _ _ _ _ _ _ _'), findsOneWidget);
    await tester.tap(byId('pin_shift_decode'));
    await tester.pump();
    expect(_visibleText('− vec:   _ _ _ _ _ _ _ _'), findsOneWidget);
    expect(find.text(l.pinShiftPaperRules(l.pinShiftDirectionDecode)),
        findsOneWidget);

    await tester.tap(byId('pin_shift_threat'));
    await tester.pumpAndSettle();
    expect(find.text(l.pinShiftThreatBody(8)), findsOneWidget);
    expect(find.text(l.pinShiftDontUseBody), findsOneWidget);
  });
}
