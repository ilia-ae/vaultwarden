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

/// Synthetic master key MK_A of yubikey_derived.json (44 ASCII bytes).
const _masterA = 'SYNTHETIC-TEST-MASTER-KEY-A-0123456789abcdef';

const _allFields = ['00', '14', '23', '24', '25', '34', '41', '45', '46'];

final RegExp _alnum = RegExp(r'^[A-Za-z0-9]+$');
final RegExp _digits = RegExp(r'^[0-9]+$');

Future<void> _openYubikey(WidgetTester tester) async {
  await _tap(tester, 'pin_tool_yubikey');
  await tester.pump();
}

Future<void> _useMaster(WidgetTester tester, String master) async {
  await _tap(tester, 'yk_source_master');
  await tester.pump();
  await tester.enterText(fieldById('yk_master_key'), master);
  await tester.pump();
}

Future<void> _serials(WidgetTester tester, String serials) async {
  await tester.enterText(fieldById('yk_serials'), serials);
  await settleDerivation(tester);
}

bool _switchOn(WidgetTester tester, String id) => tester
    .widget<Switch>(
        find.descendant(of: byId(id), matching: find.byType(Switch)))
    .value;

Future<void> _tap(WidgetTester tester, String id) async {
  await tester.ensureVisible(byId(id));
  await tester.pump();
  await tester.tap(byId(id));
}

/// Reveals the row (if needed) and returns the shown value (␣ → space).
Future<String> _value(WidgetTester tester, String serial, String field) async {
  final id = '${serial}_$field';
  expect(byId('yk_row_$id'), findsOneWidget, reason: id);
  if (byId('yk_sha_$id').evaluate().isEmpty) {
    await _tap(tester, 'yk_reveal_$id');
    await tester.pump();
  }
  // Shown in groups of four (one Text per group).
  final text = tester
      .widgetList<Text>(find.descendant(
          of: byId('yk_value_$id'), matching: find.byType(Text)))
      .map((t) => t.data!)
      .join();
  return text.replaceAll('␣', ' ');
}

String _sha(WidgetTester tester, String serial, String field) => tester
    .widget<Text>(find.descendant(
        of: byId('yk_sha_${serial}_$field'), matching: find.byType(Text)))
    .data!;

void main() {
  setUp(setPinPrefs);

  testWidgets('master key: every default-length value of MK_A and MK_E',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openYubikey(tester);
    final l = l10n(tester);

    final fixture = _fixture('yubikey_derived.json');
    final masters = {
      for (final m in fixture['masters'] as List)
        m['id'] as String: m as Map<String, dynamic>,
    };
    for (final masterId in ['MK_A_ascii44', 'MK_E_padded']) {
      final vectors = [
        for (final v in fixture['vectors'] as List)
          if (v['kind'] == 'default_length' && v['master_id'] == masterId)
            v as Map<String, dynamic>,
      ];
      final serials = {for (final v in vectors) v['serial'] as String}.toList();
      // The file bytes as pasted text: MK_E is wrapped in whitespace that
      // the script strips, so it must give the same values.
      final pasted =
          utf8.decode(_hex(masters[masterId]!['file_bytes_hex'] as String));
      await _useMaster(tester, pasted);
      // Masked key: only "long enough", never the exact byte count.
      expect(masters[masterId]!['ikm_len'] as int, greaterThanOrEqualTo(32));
      expect(find.text(l.pinYkMasterOk(32)), findsOneWidget);
      if (_switchOn(tester, 'yk_otp_from_serial')) {
        await _tap(tester, 'yk_otp_from_serial');
        await tester.pump();
      }
      await _serials(tester, serials.join(', '));
      expect(find.text(l.pinYkSerialsCount(serials.length)), findsOneWidget);
      for (final v in vectors) {
        final serial = v['serial'] as String;
        final field = v['field'] as String;
        expect(await _value(tester, serial, field), v['value'],
            reason: '$masterId $serial $field');
        expect(_sha(tester, serial, field), 'sha256_6: ${v['sha256_6']}');
      }
      // The leading-zero serial is flagged (used verbatim).
      expect(byId('yk_serials_leading_zero'), findsOneWidget);
    }
  });

  testWidgets('CSV: confirm, then byte-for-byte the script sample; cancel',
      (tester) async {
    useTallSurface(tester);
    final channel = mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openYubikey(tester);
    final l = l10n(tester);

    // Scenario S1: MK_A, three serials, all phases, OTP code from serial.
    await _useMaster(tester, _masterA);
    expect(_switchOn(tester, 'yk_otp_from_serial'), isTrue);
    await _serials(tester, '12345678, 99999999, 0012389');
    expect(await _value(tester, '12345678', '45'), '000012345678');

    await _tap(tester, 'yk_copy_csv');
    await tester.pumpAndSettle();
    expect(find.textContaining(l.pinYkCsvConfirmBody(27)), findsOneWidget);
    await _tap(tester, 'yk_csv_cancel');
    await tester.pumpAndSettle();
    expect(channel.named('copySensitive'), isEmpty);

    await _tap(tester, 'yk_copy_csv');
    await tester.pumpAndSettle();
    await _tap(tester, 'yk_csv_confirm');
    await tester.pumpAndSettle();
    final copy = channel.named('copySensitive').single;
    final sample = File('test/pin_tools/fixtures/yubikey_export_sample.csv')
        .readAsStringSync();
    expect(copy.arguments, {'text': sample, 'ttlSeconds': 60});
    expect(find.text(l.pinCopiedTtl), findsOneWidget);
    expect(l.pinYkCopyCsv, contains('Bitwarden'));
  });

  testWidgets('CSV is refused with a reason when a value fails the check',
      (tester) async {
    useTallSurface(tester);
    final channel = mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openYubikey(tester);
    final l = l10n(tester);

    // 13 digits: the OTP code from the serial is 13 characters long.
    await _useMaster(tester, _masterA);
    await _serials(tester, '1234567890123');
    expect(byId('yk_serials_otp_too_long'), findsOneWidget);
    expect(byId('yk_problem_1234567890123_45'), findsOneWidget);
    expect(find.text(l.pinYkProblemLengthExact(13, 12)), findsWidgets);

    await _tap(tester, 'yk_copy_csv');
    await tester.pumpAndSettle();
    // Master-key source: no Ledger charset advice, but the OTP cause.
    expect(find.text('${l.pinYkCsvRefusedValues} ${l.pinYkCsvRefusedOtp}'),
        findsOneWidget);
    expect(byId('yk_csv_confirm'), findsNothing);
    await _tap(tester, 'yk_csv_refused_ok');
    await tester.pumpAndSettle();
    expect(channel.named('copySensitive'), isEmpty);
  });

  testWidgets('Ledger: seed cached by PIN 24 (abandon×11 about) vs fixture',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    final container = await pumpPin(tester, tool: PinTool.pin24);
    final l = l10n(tester);

    await enterPin24(tester, seed: abandon12, nickname: 'yk-38715242-pins');
    await _openYubikey(tester);
    expect(find.text(l.pinYkUsingSeed(12)), findsOneWidget);

    final vectors = [
      for (final v in _fixture('yubikey_ledger.json')['vectors'] as List)
        if (v['seed'] == 'abandon12') v as Map<String, dynamic>,
    ];
    Map<String, dynamic> vector(String serial, String mask) => vectors
        .firstWhere((v) => v['serial'] == serial && v['mask_name'] == mask);
    final serials = ['38715242', '17684504', '00012345', '12345678'];

    await _serials(tester, serials.join('\n'));
    for (final s in serials) {
      final v = vector(s, 'device_default');
      final pins = v['pins'] as Map<String, dynamic>;
      expect(await _value(tester, s, '00'), pins['first4_last4'], reason: s);
      expect(await _value(tester, s, '14'), v['puk']['first4_last4']);
      expect(await _value(tester, s, '23'), pins['full']);
      expect(await _value(tester, s, '24'), pins['full']);
      expect(await _value(tester, s, '34'), pins['full']);
      expect(await _value(tester, s, '45'), s.padLeft(12, '0'));
      expect(await _value(tester, s, '46'), s.padLeft(12, '0'));
      // 25 and 41 never come from Ledger: random by default.
      expect(await _value(tester, s, '25'), matches(_alnum));
      expect((await _value(tester, s, '41')).length, 32);
      expect(byId('yk_warning_${s}_24'), findsOneWidget);
      expect(find.text(l.pinYkEntries(ltrIsolate('yk-$s-pins · yk-$s-puk'))),
          findsOneWidget);
    }
    expect(byId('yk_random_warning'), findsOneWidget);
    expect(find.text(l.pinYkWarnAdminShares), findsNWidgets(4));
    expect(byId('yk_serials_leading_zero'), findsOneWidget);
    // Ledger mode: OTP codes always come from the serial.
    expect(
        tester
            .widget<Switch>(find.descendant(
                of: byId('yk_otp_from_serial'), matching: find.byType(Switch)))
            .onChanged,
        isNull);

    // Separate admin entry: 24 = the whole yk-<serial>-admin output.
    await _tap(tester, 'yk_separate_admin');
    await settleDerivation(tester);
    expect(await _value(tester, '38715242', '24'),
        vector('38715242', 'device_default')['admin']['full']);
    expect(byId('yk_warning_38715242_24'), findsNothing);
    expect(
        find.text(l.pinYkEntries(ltrIsolate(
            'yk-38715242-pins · yk-38715242-puk · yk-38715242-admin'))),
        findsOneWidget);

    // Digits only (mask 0x04).
    await _tap(tester, 'yk_mask_upper');
    await _tap(tester, 'yk_mask_lower');
    await settleDerivation(tester);
    expect(byId('yk_mask_nondefault'), findsOneWidget);
    expect(await _value(tester, '17684504', '00'),
        vector('17684504', 'digits')['pins']['first4_last4']);
    expect(await _value(tester, '17684504', '14'),
        vector('17684504', 'digits')['puk']['first4_last4']);

    // Letters + digits + separators (0x3F): the 8 picked characters of
    // 38715242 contain a space → blocked, and the CSV is refused.
    await _tap(tester, 'yk_mask_upper');
    await _tap(tester, 'yk_mask_lower');
    await _tap(tester, 'yk_mask_separators');
    await settleDerivation(tester);
    expect(await _value(tester, '38715242', '00'),
        vector('38715242', 'alnum_sep')['pins']['first4_last4']);
    expect(byId('yk_problem_38715242_00'), findsOneWidget);
    expect(find.text(l.pinYkLedgerProblemAscii8), findsWidgets);
    await _tap(tester, 'yk_copy_csv');
    await tester.pumpAndSettle();
    expect(
        find.text('${l.pinYkCsvRefusedValues} ${l.pinYkCsvRefusedLedgerHint}'),
        findsOneWidget);
    await _tap(tester, 'yk_csv_refused_ok');
    await tester.pumpAndSettle();

    // Fields 25/41 from the master key instead of random.
    await _tap(tester, 'yk_mask_separators');
    await _tap(tester, 'yk_rest_master');
    await tester.pump();
    expect(find.text(l.pinYkMasterMissing), findsWidgets);
    await tester.enterText(fieldById('yk_master_key'), _masterA);
    await settleDerivation(tester);
    expect(await _value(tester, '12345678', '25'), 'NeoxmBIXYfIw');
    expect(await _value(tester, '12345678', '41'), 'HlrxRBAFFsQVDViD');
    expect(await _value(tester, '12345678', '00'),
        vector('12345678', 'device_default')['pins']['first4_last4']);

    // 🧹 in PIN 24 (seed-only wipe) drops the Ledger results.
    container
        .read(pinSessionProvider)
        .wipe(scope: PinWipeScope.seed, reason: PinWipeReason.user);
    await tester.pump();
    expect(byId('yk_result_12345678'), findsNothing);
    expect(byId('yk_go_pin24'), findsOneWidget);
    expect(fieldText(tester, 'yk_serials'), isNotEmpty);
  });

  // Trace BW12 (docs/BITWARDEN.md transition): 00/23/34 may still be set by
  // hand; such a field is not derived, not shown and not in the CSV.
  testWidgets('Ledger: fields set by hand are left out, with a note',
      (tester) async {
    useTallSurface(tester);
    final channel = mockPrivacyChannel(tester);
    await pumpPin(tester, tool: PinTool.pin24);
    final l = l10n(tester);

    // The seed alone is enough (cached as soon as the phrase is valid).
    await tester.enterText(fieldById('pin24_seed'), abandon12);
    await settleDerivation(tester);
    await _openYubikey(tester);
    await _serials(tester, '38715242');
    expect(byId('yk_row_38715242_00'), findsOneWidget);
    expect(byId('yk_hand_set_note'), findsNothing);

    await _tap(tester, 'yk_hand_00');
    await settleDerivation(tester);
    expect(byId('yk_row_38715242_00'), findsNothing);
    expect(byId('yk_row_38715242_14'), findsOneWidget);
    expect(find.text(l.pinYkHandSetNote(ltrIsolate('00'))), findsOneWidget);

    await _tap(tester, 'yk_copy_csv');
    await tester.pumpAndSettle();
    await _tap(tester, 'yk_csv_confirm');
    await tester.pumpAndSettle();
    final csv = (channel.named('copySensitive').single.arguments as Map)['text']
        as String;
    expect(csv, isNot(contains('38715242,00 ')));
    expect(csv, contains('38715242,14 '));
    expect(csv, contains('38715242,23 '));
  });

  testWidgets('Ledger without a cached seed: a button leads to PIN 24',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openYubikey(tester);
    final l = l10n(tester);

    await _serials(tester, '38715242');
    expect(find.text(l.pinYkNeedSeed), findsOneWidget);
    expect(find.text(l.pinYkGateNoSeed), findsOneWidget);
    expect(byId('yk_result_38715242'), findsNothing);
    // No seed input in this tool.
    expect(find.byType(EditableText), findsOneWidget);

    await _tap(tester, 'yk_go_pin24');
    await tester.pump();
    expect(byId('pin24_seed'), findsOneWidget);
    expect(byId('yk_view'), findsNothing);
  });

  testWidgets('random: FIELDS shapes, stable, regenerate, warning',
      (tester) async {
    useTallSurface(tester);
    final channel = mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openYubikey(tester);
    final l = l10n(tester);

    await _tap(tester, 'yk_source_random');
    await tester.pump();
    await _serials(tester, '12345678');
    expect(find.text(l.pinYkRandomWarning), findsOneWidget);

    final first = {
      for (final f in _allFields) f: await _value(tester, '12345678', f),
    };
    expect(first['00'], matches(_digits));
    expect(first['00']!.length, 8);
    expect(first['14'], matches(_digits));
    expect(first['14']!.length, 8);
    for (final f in ['23', '24', '34']) {
      expect(first[f], matches(_alnum));
      expect(first[f]!.length, 16);
    }
    expect(first['25']!.length, 24);
    expect(first['41']!.length, 32);
    expect(first['45'], '000012345678');
    expect(first['46'], '000012345678');

    // Values stay put when something else changes.
    await _tap(tester, 'yk_phase_fido2');
    await settleDerivation(tester);
    expect(byId('yk_row_12345678_34'), findsNothing);
    await _tap(tester, 'yk_phase_fido2');
    await settleDerivation(tester);
    for (final f in _allFields) {
      expect(await _value(tester, '12345678', f), first[f], reason: f);
    }

    // OTP from serial off → random lowercase hex.
    await _tap(tester, 'yk_otp_from_serial');
    await settleDerivation(tester);
    expect(await _value(tester, '12345678', '45'), matches(r'^[0-9a-f]{12}$'));

    // Copy one value.
    await _tap(tester, 'yk_copy_12345678_00');
    await tester.pump();
    expect(channel.named('copySensitive').single.arguments,
        {'text': first['00'], 'ttlSeconds': 60});

    // Regenerate (after a confirmation) replaces them.
    await _tap(tester, 'yk_regenerate');
    await tester.pumpAndSettle();
    await _tap(tester, 'yk_regenerate_confirm');
    await tester.pumpAndSettle();
    final second = {
      for (final f in ['23', '24', '25', '41'])
        f: await _value(tester, '12345678', f),
    };
    expect(second.entries.any((e) => e.value != first[e.key]), isTrue);
  });

  testWidgets('master key: hex not decoded, byte count, clipboard, wipe',
      (tester) async {
    useTallSurface(tester);
    final channel = mockPrivacyChannel(tester);
    final container = await pumpPin(tester);
    await _openYubikey(tester);
    final l = l10n(tester);

    await _useMaster(tester, 'short');
    expect(find.text(l.pinYkMasterShort(32)), findsWidgets);
    expect(find.text(l.pinYkMasterHint), findsOneWidget);
    expect(find.text(l.pinYkMasterNeverStored), findsWidgets);

    // 64 hex characters are a 64-byte key (MK_C), not 32 decoded bytes.
    const hex64 =
        '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
    await tester.enterText(fieldById('yk_master_key'), hex64);
    await tester.pump();
    expect(find.text(l.pinYkMasterOk(32)), findsOneWidget);
    // A long insert counts as a paste: offer to clear the clipboard.
    expect(byId('yk_clear_clipboard'), findsOneWidget);
    await _tap(tester, 'yk_clear_clipboard');
    await tester.pump();
    expect(channel.named('clearClipboard'), hasLength(1));
    expect(byId('yk_clear_clipboard'), findsNothing);

    final mkC = [
      for (final v in _fixture('yubikey_derived.json')['vectors'] as List)
        if (v['master_id'] == 'MK_C_hextext' &&
            v['kind'] == 'default_length' &&
            v['serial'] == '12345678')
          v,
    ];
    await _serials(tester, '12345678');
    for (final v in mkC) {
      if (v['field'] == '45' || v['field'] == '46') continue; // from serial
      expect(
          await _value(tester, '12345678', v['field'] as String), v['value']);
    }
    expect(container.read(pinSessionProvider).hasContent, isTrue);

    // A seed-only wipe (🧹 in PIN 24) leaves master-key values alone.
    container
        .read(pinSessionProvider)
        .wipe(scope: PinWipeScope.seed, reason: PinWipeReason.user);
    await settleDerivation(tester);
    expect(byId('yk_result_12345678'), findsOneWidget);
    expect(fieldText(tester, 'yk_master_key'), hex64);

    // A full wipe clears the master key, the serials and the table.
    container.read(pinSessionProvider).wipe(reason: PinWipeReason.background);
    await tester.pump();
    expect(fieldText(tester, 'yk_master_key'), isEmpty);
    expect(fieldText(tester, 'yk_serials'), isEmpty);
    expect(byId('yk_result_12345678'), findsNothing);
    expect(byId('yk_sha_12345678_00'), findsNothing);
    expect(container.read(pinSessionProvider).hasContent, isFalse);
  });

  testWidgets('serial list: separators, duplicates, invalid tokens, Clear',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openYubikey(tester);
    final l = l10n(tester);

    await _useMaster(tester, _masterA);
    await _serials(tester, '12345678; 12345678\n99999999');
    expect(find.text(l.pinYkSerialsCount(2)), findsOneWidget);
    expect(find.text(l.pinYkSerialsDuplicates(ltrIsolate('12345678'))),
        findsOneWidget);
    expect(byId('yk_result_99999999'), findsOneWidget);

    await _serials(tester, '12345678, 12a4, ١٢٣');
    expect(find.text(l.pinYkSerialsInvalid(ltrIsolate('“12a4”, “١٢٣”'))),
        findsOneWidget);
    expect(find.text(l.pinYkGateBadSerials), findsOneWidget);
    expect(byId('yk_result_12345678'), findsNothing);

    await _serials(tester, '12345678');
    expect(byId('yk_result_12345678'), findsOneWidget);
    await _tap(tester, 'yk_clear');
    await tester.pump();
    expect(fieldText(tester, 'yk_serials'), isEmpty);
    expect(fieldText(tester, 'yk_master_key'), isEmpty);
    expect(byId('yk_result_12345678'), findsNothing);
  });

  testWidgets('notes: hardware limits, YubiKey Bio, desktop-only',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    await _openYubikey(tester);
    final l = l10n(tester);

    await _tap(tester, 'yk_notes');
    await tester.pumpAndSettle();
    expect(byId('yk_hw_limits'), findsOneWidget);
    expect(find.text(l.pinYkHwBytes(6, 8)), findsNWidgets(2));
    expect(find.text(l.pinYkHwChars(4, 63)), findsOneWidget);
    expect(find.text(l.pinYkHwExactHex(12)), findsNWidgets(2));
    expect(find.text(l.pinYkBioNote), findsOneWidget);
    expect(find.text(l.pinYkPolicyNote), findsOneWidget);
    expect(find.text(l.pinYkDesktopOnlyNote), findsWidgets);
  });

  testWidgets('narrow phone (360 pt): every tool lays out without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 30000);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    mockPrivacyChannel(tester);
    await pumpPin(tester, locale: const Locale('ru'));

    await tester.tap(byId('pin_tool_shift'));
    await tester.pump();
    await tester.tap(byId('pin_shift_len_8'));
    await tester.pump();
    await tester.enterText(fieldById('pin_shift_pin'), '12345678');
    await tester.enterText(fieldById('pin_shift_vector'), '37193719');
    await tester.pump();
    await _tap(tester, 'pin_shift_reveal');
    await tester.pump();
    await _tap(tester, 'pin_shift_breakdown');
    await tester.pumpAndSettle();
    await _tap(tester, 'pin_shift_paper');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await _openYubikey(tester);
    await _useMaster(tester, _masterA);
    await _serials(tester, '12345678, 1234567890123456789012');
    await _value(tester, '1234567890123456789012', '41');
    await _tap(tester, 'yk_notes');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await _tap(tester, 'pin_show_legacy');
    await tester.pump();
    await _tap(tester, 'pin_tool_legacy');
    await tester.pump();
    await tester.enterText(fieldById('legacy_mask_mask'), '24681357');
    await tester.enterText(
        fieldById('legacy_mask_input'), 'ABCDEFGHIJKLMNOPQRST');
    await tester.pump();
    await _tap(tester, 'legacy_mask_reveal');
    await tester.pump();
    expect(byId('legacy_mask_walk'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('RTL (ar): every tool renders, values stay left-to-right',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester, locale: const Locale('ar'));

    await _tap(tester, 'pin_tool_shift');
    await tester.pump();
    // The default length (8): a real result, not the empty cells.
    await tester.enterText(fieldById('pin_shift_pin'), '12345678');
    await tester.enterText(fieldById('pin_shift_vector'), '37193719');
    await tester.pump();
    expect(byId('pin_shift_roundtrip'), findsOneWidget);
    final cells = find.descendant(
        of: byId('pin_shift_output'), matching: find.byType(Directionality));
    expect(tester.widget<Directionality>(cells.first).textDirection,
        TextDirection.ltr);

    await _openYubikey(tester);
    await _useMaster(tester, _masterA);
    await _serials(tester, '12345678');
    expect(await _value(tester, '12345678', '00'), '77747579');

    await _tap(tester, 'pin_show_legacy');
    await tester.pump();
    await _tap(tester, 'pin_tool_legacy');
    await tester.pump();
    expect(byId('legacy_mask_view'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

List<int> _hex(String hex) => [
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
