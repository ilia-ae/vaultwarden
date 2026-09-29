// PIN 24: nickname list import from a Ledger Passwords backup (plan C1 "after
// the merge", spec pin24-ui §2.9 + §8 slot_*, critic pin24-ui #4). Synthetic
// JSON only; the picker is replaced by a fake that hands out bytes.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/pin_tools/ledger_pin24.dart';
import 'package:vault_approver/screens/pin/nickname_backup.dart';
import 'package:vault_approver/screens/pin/nickname_backup_picker.dart';
import 'package:vault_approver/screens/pin/pin24_engine.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';
import 'package:vault_approver/screens/pin/pin_widgets.dart';
import 'package:vault_approver/widgets/option_pills.dart';

import 'pin_harness.dart';

/// Hands out queued results: bytes, `null` (cancelled) or an exception.
class _FakePicker {
  _FakePicker([List<Object?> results = const []]) : _results = [...results];

  final List<Object?> _results;
  int calls = 0;

  void add(Object? result) => _results.add(result);

  Future<Uint8List?> call() async {
    calls++;
    final r = _results.removeAt(0);
    if (r is Exception) throw r;
    return r as Uint8List?;
  }
}

Uint8List _json(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

/// A synthetic backup covering every case the UI distinguishes.
final _backup = _json({
  'key_id': 'key-test',
  'description': 'synthetic',
  'parsed': [
    {
      'nickname': 'gmail',
      'charsets': ['UPPERCASE', 'LOWERCASE', 'NUMBERS'],
    },
    {
      'nickname': 'visa',
      'charsets': ['NUMBERS', 'MINUS', 'UNDERLINE', 'SPACE'],
    },
    {'nickname': 'no-charsets'},
    {
      'nickname': 'dash-only',
      'charsets': ['MINUS'],
    },
    {'nickname': 'twenty-bytes-long-xx'},
    {
      'nickname': 'broken',
      'charsets': ['NOPE'],
    },
  ],
});

Future<ProviderContainer> _pump(WidgetTester tester, _FakePicker picker) {
  useTallSurface(tester);
  mockPrivacyChannel(tester);
  return pumpPin(tester, overrides: [
    nicknameBackupPickerProvider.overrideWithValue(picker.call),
  ]);
}

Future<void> _tap(WidgetTester tester, String id) async {
  await tester.ensureVisible(byId(id));
  await tester.pump();
  await tester.tap(byId(id));
  await tester.pump();
}

Future<void> _openImport(WidgetTester tester) async {
  if (byId('pin24_import_file').evaluate().isEmpty &&
      byId('pin24_import_choose').evaluate().isEmpty) {
    await _tap(tester, 'pin24_import');
    await tester.pumpAndSettle();
  }
}

Future<void> _import(WidgetTester tester) async {
  await _openImport(tester);
  await _tap(tester, 'pin24_import_file');
  await tester.pump();
  await tester.pump();
}

Future<void> _choose(WidgetTester tester, int index) async {
  await _tap(tester, 'pin24_import_choose');
  await tester.pumpAndSettle();
  await tester.tap(byId('pin24_import_entry_$index'));
  await tester.pumpAndSettle();
}

bool _pillOn(WidgetTester tester, String id) => tester
    .widget<OptionPill>(
        find.ancestor(of: byId(id), matching: find.byType(OptionPill)))
    .selected;

/// Every visible string, to check that no file content leaks.
Iterable<String> _texts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '');

void main() {
  setUp(setPinPrefs);

  testWidgets('import before the seed, choose an entry, derive (Speculos)',
      (tester) async {
    final picker = _FakePicker([_backup]);
    final container = await _pump(tester, picker);
    final l = l10n(tester);

    await _import(tester);
    expect(picker.calls, 1);
    expect(find.text(l.pin24ImportLoaded(5)), findsOneWidget);
    expect(find.text(l.pin24ImportSkipped(1)), findsOneWidget);
    expect(container.read(pinSessionProvider).nicknameBackup!.entries,
        hasLength(5));

    // The list shows every usable entry with its charsets.
    await _tap(tester, 'pin24_import_choose');
    await tester.pumpAndSettle();
    expect(find.text(l.pin24ImportChooseTitle), findsOneWidget);
    Finder inDialog(Finder f) =>
        find.descendant(of: find.byType(AlertDialog), matching: f);
    for (final nick in ['gmail', 'visa', 'no-charsets', 'dash-only']) {
      expect(inDialog(find.text(nick)), findsOneWidget, reason: nick);
    }
    expect(inDialog(find.text(ltrIsolate('MINUS (-)'))), findsOneWidget);
    expect(inDialog(find.text(ltrIsolate('A-Z + a-z + 0-9'))), findsOneWidget);
    await tester.tap(byId('pin24_import_entry_0'));
    await tester.pumpAndSettle();

    // gmail: A-Z + a-z + 0-9 → Password mode with those toggles.
    expect(fieldText(tester, 'pin24_nickname'), 'gmail');
    expect(_pillOn(tester, 'pin24_mode_password'), isTrue);
    expect(_pillOn(tester, 'pin24_cs_upper'), isTrue);
    expect(_pillOn(tester, 'pin24_cs_lower'), isTrue);
    expect(_pillOn(tester, 'pin24_cs_digits'), isTrue);
    expect(_pillOn(tester, 'pin24_cs_separators'), isFalse);
    expect(_pillOn(tester, 'pin24_cs_specials'), isFalse);

    // The list stays usable once the seed is in (no picker involved).
    await tester.enterText(fieldById('pin24_seed'), speculos24);
    await settleDerivation(tester);
    // Official LedgerHQ vector, mask 0x07.
    expect(outputText(tester), 'xNX8IQO4vP0ucO41J6JW');
    expect(byId('pin24_import_choose'), findsOneWidget);

    // visa: numbers + separators → PIN mode.
    await _choose(tester, 1);
    await settleDerivation(tester);
    expect(fieldText(tester, 'pin24_nickname'), 'visa');
    expect(_pillOn(tester, 'pin24_mode_pin'), isTrue);
    expect(displayedPin(tester), isNotEmpty);
    expect(picker.calls, 1);
  });

  testWidgets('import is disabled once a seed is typed or cached',
      (tester) async {
    final picker = _FakePicker([_backup]);
    await _pump(tester, picker);
    final l = l10n(tester);
    await _openImport(tester);
    expect(byId('pin24_import_blocked'), findsNothing);

    await tester.enterText(fieldById('pin24_seed'), 'aban');
    await tester.pump();
    expect(byId('pin24_import_blocked'), findsOneWidget);
    expect(find.text(l.pin24ImportBlocked), findsOneWidget);
    expect(
        tester
            .widget<OutlinedButton>(find.descendant(
                of: byId('pin24_import_file'),
                matching: find.byType(OutlinedButton)))
            .onPressed,
        isNull);
    await tester.tap(byId('pin24_import_file'), warnIfMissed: false);
    await tester.pump();
    expect(picker.calls, 0);

    await tester.enterText(fieldById('pin24_seed'), '');
    await tester.pump();
    expect(byId('pin24_import_blocked'), findsNothing);

    // A passphrase alone blocks it too.
    await _tap(tester, 'pin24_passphrase_section');
    await tester.pumpAndSettle();
    await tester.enterText(fieldById('pin24_passphrase'), 'TREZOR');
    await tester.pump();
    expect(byId('pin24_import_blocked'), findsOneWidget);
    await tester.enterText(fieldById('pin24_passphrase'), '');
    await tester.pump();
    expect(byId('pin24_import_blocked'), findsNothing);

    // A seed cached for the section (field empty again after a tool
    // switch) still blocks it.
    await tester.enterText(fieldById('pin24_seed'), abandon12);
    await settleDerivation(tester);
    await _tap(tester, 'pin_tool_yubikey');
    await tester.pumpAndSettle();
    await _tap(tester, 'pin_tool_pin24');
    await tester.pumpAndSettle();
    expect(fieldText(tester, 'pin24_seed'), isEmpty);
    await _openImport(tester);
    expect(byId('pin24_import_blocked'), findsOneWidget);
    expect(picker.calls, 0);

    // Wiping the seed makes it available again.
    await _tap(tester, 'pin_wipe_cached_seed');
    await tester.pumpAndSettle();
    await _openImport(tester);
    expect(byId('pin24_import_blocked'), findsNothing);
    await _tap(tester, 'pin24_import_file');
    await tester.pump();
    expect(picker.calls, 1);
  });

  testWidgets('a typed nickname is replaced only after confirmation',
      (tester) async {
    await _pump(tester, _FakePicker([_backup]));
    final l = l10n(tester);
    await _import(tester);

    await tester.enterText(fieldById('pin24_nickname'), 'typed');
    await tester.pump();
    await _choose(tester, 0);
    expect(find.text(l.pin24ImportReplaceTitle), findsOneWidget);
    await tester.tap(byId('pin24_import_replace_cancel'));
    await tester.pumpAndSettle();
    expect(fieldText(tester, 'pin24_nickname'), 'typed');
    expect(_pillOn(tester, 'pin24_mode_pin'), isTrue, reason: 'unchanged');

    await _choose(tester, 0);
    await tester.tap(byId('pin24_import_replace_confirm'));
    await tester.pumpAndSettle();
    expect(fieldText(tester, 'pin24_nickname'), 'gmail');
    expect(_pillOn(tester, 'pin24_mode_password'), isTrue);

    // Same nickname again: nothing to overwrite, no question.
    await _choose(tester, 0);
    expect(find.text(l.pin24ImportReplaceTitle), findsNothing);
    expect(fieldText(tester, 'pin24_nickname'), 'gmail');

    // A nickname that came from the list is replaced without a question...
    await _choose(tester, 1);
    expect(find.text(l.pin24ImportReplaceTitle), findsNothing);
    expect(fieldText(tester, 'pin24_nickname'), 'visa');
    // ...but once edited it is the user's again.
    await tester.enterText(fieldById('pin24_nickname'), 'visa2');
    await tester.pump();
    await _choose(tester, 0);
    expect(find.text(l.pin24ImportReplaceTitle), findsOneWidget);
    await tester.tap(byId('pin24_import_replace_cancel'));
    await tester.pumpAndSettle();
    expect(fieldText(tester, 'pin24_nickname'), 'visa2');
  });

  testWidgets('missing charsets → ALL_SETS: all five toggles on',
      (tester) async {
    await _pump(tester, _FakePicker([_backup]));
    await _import(tester);
    await _choose(tester, 2);
    expect(fieldText(tester, 'pin24_nickname'), 'no-charsets');
    expect(_pillOn(tester, 'pin24_mode_password'), isTrue);
    for (final c in Pin24Charset.values) {
      expect(_pillOn(tester, 'pin24_cs_${c.name}'), isTrue, reason: c.name);
    }
    expect(byId('pin24_raw_mask'), findsNothing);
  });

  testWidgets('MINUS-only → raw mask with the exact sets and a warning',
      (tester) async {
    await _pump(tester, _FakePicker([_backup]));
    final l = l10n(tester);
    await _import(tester);
    await _choose(tester, 3);
    await tester.enterText(fieldById('pin24_seed'), abandon12);
    await settleDerivation(tester);

    expect(byId('pin24_raw_mask'), findsOneWidget);
    expect(find.text(l.pin24ImportRawMask(ltrIsolate('MINUS (-) · 0x08'))),
        findsOneWidget);
    expect(byId('pin24_cs_upper'), findsNothing, reason: 'toggles hidden');
    // Derived with exactly mask 0x08 (the core, not the toggles).
    final expected = derivePassword(
      bip39Seed: bip39ToSeed(abandon12),
      nickname: 'dash-only',
      setMask: kMinus,
    );
    expect(outputText(tester), withVisibleSpaces(expected));
    expect(expected, matches(RegExp(r'^-{20}$')));
    expect(
        find.text(l.pin24PasswordCaption(ltrIsolate('MINUS (-)'), 'dash-only')),
        findsOneWidget);

    // Back to the toggles: the device defaults of the toggles apply.
    await _tap(tester, 'pin24_raw_mask_exit');
    await settleDerivation(tester);
    expect(byId('pin24_raw_mask'), findsNothing);
    expect(byId('pin24_cs_upper'), findsOneWidget);
    expect(outputText(tester), isNot(withVisibleSpaces(expected)));
  });

  testWidgets('a nickname over 19 bytes keeps its soft warning',
      (tester) async {
    await _pump(tester, _FakePicker([_backup]));
    final l = l10n(tester);
    await _import(tester);
    await _choose(tester, 4);
    expect(fieldText(tester, 'pin24_nickname'), 'twenty-bytes-long-xx');
    expect(find.text(l.pin24NicknameTooLong(20, kLedgerMaxNicknameBytes)),
        findsOneWidget);
  });

  testWidgets('read errors show fixed text and never the file content',
      (tester) async {
    final picker = _FakePicker([
      Uint8List.fromList(utf8.encode('{"parsed": [{"nickname": "LEAKME"')),
      _json({'parsed': []}),
      const NicknameBackupException(NicknameBackupError.tooLarge),
      Uint8List(kNicknameBackupMaxBytes + 1),
      Exception('picker exploded: /private/LEAKME.json'),
      null, // cancelled
    ]);
    await _pump(tester, picker);
    final l = l10n(tester);

    Future<void> expectError(String text) async {
      await _import(tester);
      expect(byId('pin24_import_error'), findsOneWidget);
      expect(find.text(text), findsOneWidget);
      expect(_texts(tester).where((t) => t.contains('LEAKME')), isEmpty);
      expect(byId('pin24_import_loaded'), findsNothing);
    }

    await expectError(l.pin24ImportErrorRead);
    await expectError(l.pin24ImportErrorEmpty);
    await expectError(l.pin24ImportErrorTooLarge);
    await expectError(l.pin24ImportErrorTooLarge);
    await expectError(l.pin24ImportErrorRead);

    // Cancelling clears the old error and loads nothing.
    await _import(tester);
    expect(byId('pin24_import_error'), findsNothing);
    expect(byId('pin24_import_loaded'), findsNothing);
    expect(picker.calls, 6);
  });

  testWidgets(
      'the list lives in the section: kept across tools, wiped by '
      'Wipe all, Forget list', (tester) async {
    final picker = _FakePicker([_backup, _backup]);
    final container = await _pump(tester, picker);
    final l = l10n(tester);
    await _import(tester);
    await _choose(tester, 3); // raw mask
    expect(byId('pin24_raw_mask'), findsOneWidget);

    await _tap(tester, 'pin_tool_shift');
    await tester.pumpAndSettle();
    await _tap(tester, 'pin_tool_pin24');
    await tester.pumpAndSettle();
    await _openImport(tester);
    expect(find.text(l.pin24ImportLoaded(5)), findsOneWidget);

    // Wipe all (🚨): the list and its raw mask go too.
    await _tap(tester, 'pin24_wipe_all');
    await tester.pumpAndSettle();
    await tester.tap(byId('pin24_wipe_all_confirm'));
    await tester.pumpAndSettle();
    expect(container.read(pinSessionProvider).nicknameBackup, isNull);
    expect(byId('pin24_import_loaded'), findsNothing);
    expect(byId('pin24_raw_mask'), findsNothing);

    // Forget list.
    await _import(tester);
    expect(byId('pin24_import_loaded'), findsOneWidget);
    await _tap(tester, 'pin24_import_forget');
    await tester.pump();
    expect(container.read(pinSessionProvider).nicknameBackup, isNull);
    expect(byId('pin24_import_file'), findsOneWidget);
  });

  testWidgets('a background wipe drops the list', (tester) async {
    resetLifecycleOnTearDown(tester);
    final container = await _pump(tester, _FakePicker([_backup]));
    await _import(tester);
    expect(container.read(pinSessionProvider).nicknameBackup, isNotNull);
    setLifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    setLifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    expect(container.read(pinSessionProvider).nicknameBackup, isNull);
  });
}
