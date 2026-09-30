// PIN Shift: "remember the shift vector" — saved in the keychain, used
// automatically, never shown again (to see it, enter it again).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_approver/screens/pin/pin_prefs.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';
import 'package:vault_approver/services/pin_shift_vector_store.dart';
import 'package:vault_approver/services/secure_storage_service.dart';

import 'pin_harness.dart';

const _key = SecureStorageService.keyPinShiftVector;

/// The app's keychain store over the mocked plugin, counting the calls.
class _CountingStore implements PinShiftVectorStore {
  _CountingStore([SecureStorageService? inner])
      : inner = inner ?? SecureStorageService();

  final SecureStorageService inner;
  int loads = 0;

  @override
  Future<String?> loadShiftVector() {
    loads++;
    return inner.loadShiftVector();
  }

  @override
  Future<void> saveShiftVector(String vector) => inner.saveShiftVector(vector);

  @override
  Future<void> deleteShiftVector() => inner.deleteShiftVector();
}

/// A keychain whose reads fail (locked device, keystore failure) until
/// [failing] is cleared; everything else is the mocked plugin.
class _FlakyKeychain extends FlutterSecureStorage {
  _FlakyKeychain()
      : super(
          aOptions: SecureStorageService.androidOptions,
          iOptions: SecureStorageService.iosOptions,
        );

  bool failing = true;

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) {
    if (failing) {
      throw PlatformException(code: 'keystore', message: 'unreadable');
    }
    return super.read(key: key);
  }
}

/// What the mocked keychain holds.
Future<Map<String, String>> _keychain() => const FlutterSecureStorage(
      aOptions: SecureStorageService.androidOptions,
      iOptions: SecureStorageService.iosOptions,
    ).readAll();

Future<Map<String, Object>> _prefs() async {
  final prefs = await SharedPreferences.getInstance();
  return {for (final k in prefs.getKeys()) k: prefs.get(k)!};
}

/// Pumps the PIN section with [store] as the keychain and lets the saved
/// vector load.
Future<ProviderContainer> _pump(
  WidgetTester tester, {
  PinShiftVectorStore? store,
}) async {
  final container = await pumpPin(tester, overrides: [
    pinShiftVectorStoreProvider
        .overrideWithValue(store ?? SecureStorageService()),
  ]);
  await tester.pump();
  return container;
}

int _length(WidgetTester tester) => int.parse(tester
    .widget<Text>(find.descendant(
        of: byId('pin_shift_len_value'), matching: find.byType(Text)))
    .data!);

/// Digits shown in the cell row with Semantics identifier [id].
String _digits(WidgetTester tester, String id) => tester
    .widgetList<Text>(
        find.descendant(of: byId(id), matching: find.byType(Text)))
    .map((t) => t.data ?? '')
    .join()
    .replaceAll(RegExp(r'[^0-9]'), '');

/// Every Text under [id], joined.
String _texts(WidgetTester tester, String id) => tester
    .widgetList<Text>(
        find.descendant(of: byId(id), matching: find.byType(Text)))
    .map((t) => t.data ?? '')
    .join('|');

bool _obscured(WidgetTester tester, String id) =>
    tester.widget<EditableText>(fieldById(id)).obscureText;

bool _pillSelected(WidgetTester tester, String id) =>
    tester.widget<Semantics>(byId(id)).properties.selected ?? false;

bool _switchOn(WidgetTester tester, String id) => tester
    .widget<Switch>(
        find.descendant(of: byId(id), matching: find.byType(Switch)))
    .value;

/// Whether the button under [id] can be pressed.
bool _enabled(WidgetTester tester, String id) {
  final button = find.descendant(
      of: byId(id),
      matching: find
          .byWidgetPredicate((w) => w is ButtonStyleButton || w is IconButton));
  final w = tester.widget(button.first);
  return w is ButtonStyleButton
      ? w.enabled
      : (w as IconButton).onPressed != null;
}

Future<void> _tap(WidgetTester tester, String id) async {
  await tester.ensureVisible(byId(id));
  await tester.tap(byId(id));
  await tester.pump();
  await tester.pump();
}

/// The texts of column [column] of the per-digit table, below the header.
List<String> _tableColumn(WidgetTester tester, int column) {
  final table = tester.widget<Table>(find.descendant(
      of: byId('pin_shift_breakdown'), matching: find.byType(Table)));
  return [
    for (final row in table.children.skip(1))
      tester
          .widgetList<Text>(find.descendant(
              of: find.byWidget(row.children[column]),
              matching: find.byType(Text)))
          .map((t) => t.data ?? '')
          .join(),
  ];
}

/// Every run of 3+ consecutive digits of [vector], plain and spaced
/// ("908" and "9 0 8"): the ways a UI could spell (part of) it.
List<String> _spellings(String vector) => [
      for (var len = 3; len <= vector.length; len++)
        for (var i = 0; i + len <= vector.length; i++) ...[
          vector.substring(i, i + len),
          vector.substring(i, i + len).split('').join(' '),
        ],
    ];

/// Fails if any widget text (Text, RichText, fields) or any semantics
/// label, value, hint or tooltip spells [vector].
void _expectNowhere(WidgetTester tester, String vector) {
  final nodes = tester.semantics.simulatedAccessibilityTraversal().toList();
  expect(nodes, isNotEmpty);
  final spoken = [
    for (final n in nodes)
      for (final s in [
        n.getSemanticsData().label,
        n.getSemanticsData().value,
        n.getSemanticsData().hint,
        n.getSemanticsData().tooltip,
      ])
        if (s.isNotEmpty) s,
  ];
  for (final s in _spellings(vector)) {
    expect(find.textContaining(s, findRichText: true), findsNothing,
        reason: 'text "$s"');
    expect(spoken.where((t) => t.contains(s)), isEmpty,
        reason: 'semantics "$s"');
  }
}

void main() {
  setUp(() {
    setPinPrefs();
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('no keychain wired: no Save, the tool works as before',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    expect(byId('pin_shift_vector'), findsOneWidget);
    expect(byId('pin_shift_vector_save'), findsNothing);
    expect(byId('pin_shift_vector_saved'), findsNothing);
    expect(byId('pin_shift_vector_loading'), findsNothing);
  });

  testWidgets(
      'save: 12345678 + saved 11111111 = 23456789, decode back; only the '
      'PIN is typed from then on', (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    final container = await _pump(tester);
    final l = l10n(tester);

    // (a) Nothing saved: the field, its eye and a disabled Save.
    expect(byId('pin_shift_vector'), findsOneWidget);
    expect(byId('pin_shift_vector_eye'), findsOneWidget);
    expect(_enabled(tester, 'pin_shift_vector_save'), isFalse);
    expect(find.text(l.pinShiftVectorSave), findsOneWidget);
    expect(find.text(l.pinShiftVectorSaveHelp), findsOneWidget);

    // Wrong length: still disabled. Revealing while typing is allowed.
    await tester.enterText(fieldById('pin_shift_vector'), '1111');
    await tester.pump();
    expect(_enabled(tester, 'pin_shift_vector_save'), isFalse);
    await tester.enterText(fieldById('pin_shift_vector'), '11111111');
    await tester.pump();
    await _tap(tester, 'pin_shift_vector_eye');
    expect(_obscured(tester, 'pin_shift_vector'), isFalse);
    expect(_enabled(tester, 'pin_shift_vector_save'), isTrue);

    await _tap(tester, 'pin_shift_vector_save');
    expect(find.text(l.pinShiftVectorSavedSnack), findsOneWidget);
    expect((await _keychain())[_key], '11111111');
    // Never in the preferences: only the (unchanged) length.
    for (final v in (await _prefs()).values) {
      expect('$v', isNot(contains('11111111')));
    }

    // (b) Saved: masked cells, no field, no eye, Replace and Delete.
    expect(byId('pin_shift_vector_saved'), findsOneWidget);
    expect(find.text(l.pinShiftVectorSavedTitle(8)), findsOneWidget);
    expect(find.text(l.pinShiftVectorSavedHelp), findsOneWidget);
    expect(_texts(tester, 'pin_shift_vector_saved'), contains('•|•|•|•'));
    expect(_digits(tester, 'pin_shift_vector_saved'), '8',
        reason: 'only the "8 digits" title');
    expect(byId('pin_shift_vector'), findsNothing);
    expect(byId('pin_shift_vector_eye'), findsNothing);
    expect(byId('pin_shift_vector_save'), findsNothing);
    expect(byId('pin_shift_vector_replace'), findsOneWidget);
    expect(byId('pin_shift_vector_delete'), findsOneWidget);
    expect(find.text(l.pinShiftFillPin(8)), findsOneWidget);
    expect(container.read(pinSessionProvider).hasContent, isFalse,
        reason: 'the typed vector left the field');

    await tester.enterText(fieldById('pin_shift_pin'), '12345678');
    await tester.pump();
    expect(_digits(tester, 'pin_shift_output'), '23456789');
    expect(find.text(l.pinShiftRoundTripOk), findsOneWidget);
    expect(find.text(l.pinShiftHiddenNoteSaved), findsOneWidget);

    await _tap(tester, 'pin_shift_decode');
    await tester.enterText(fieldById('pin_shift_pin'), '23456789');
    await tester.pump();
    expect(_digits(tester, 'pin_shift_output'), '12345678');
    expect(find.text(l.pinShiftRoundTripOkDecode), findsOneWidget);
  });

  testWidgets(
      'a saved vector is never shown: no eye, Reveal shows only the PIN, '
      'masked breakdown, no digits in any text or semantics', (tester) async {
    FlutterSecureStorage.setMockInitialValues({_key: '90817263'});
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    final handle = tester.ensureSemantics();
    await _pump(tester);
    final l = l10n(tester);

    expect(byId('pin_shift_vector_saved'), findsOneWidget);
    expect(byId('pin_shift_vector_eye'), findsNothing);
    expect(find.bySemanticsLabel(l.pinShiftVectorSavedSemantics(8)),
        findsOneWidget);
    _expectNowhere(tester, '90817263');

    // 12345678 + 90817263 = 02152831.
    await tester.enterText(fieldById('pin_shift_pin'), '12345678');
    await tester.pump();
    expect(_digits(tester, 'pin_shift_output'), '02152831');

    // Reveal: the PIN and the output, the vector row masked.
    expect(find.text(l.pinShiftRevealSaved), findsOneWidget);
    expect(find.text(l.pinShiftRevealHelpSaved), findsOneWidget);
    expect(find.text(l.pinShiftReveal), findsNothing);
    await _tap(tester, 'pin_shift_reveal');
    expect(_switchOn(tester, 'pin_shift_reveal'), isTrue);
    expect(_digits(tester, 'pin_shift_input_row'), '12345678');
    expect(_digits(tester, 'pin_shift_vector_row'), isEmpty);
    expect(_texts(tester, 'pin_shift_vector_row'), contains('•|•|•|•'));
    expect(find.bySemanticsLabel(RegExp('0 2 1 5 2 8 3 1')), findsOneWidget);
    await _tap(tester, 'pin_shift_breakdown');
    await tester.pumpAndSettle();
    expect(find.text(l.pinShiftColFormula), findsOneWidget);
    expect(_tableColumn(tester, 1), '12345678'.split(''));
    expect(_tableColumn(tester, 2), List.filled(8, '•'));
    expect(_tableColumn(tester, 3), [
      for (final d in '12345678'.split('')) '($d + •) mod 10',
    ]);
    expect(_tableColumn(tester, 4), '02152831'.split(''));
    expect(byId('pin_shift_weak_zero'), findsNothing);
    expect(byId('pin_shift_weak_equal'), findsNothing);
    expect(byId('pin_shift_weak_fives'), findsNothing);

    // The paper walkthrough and the threat model use fixed examples only.
    await _tap(tester, 'pin_shift_paper');
    await _tap(tester, 'pin_shift_threat');
    await tester.pumpAndSettle();
    expect(find.text(l.pinShiftPaperDontBody), findsOneWidget);
    _expectNowhere(tester, '90817263');

    // Decode too.
    await _tap(tester, 'pin_shift_decode');
    await tester.pumpAndSettle();
    expect(_digits(tester, 'pin_shift_output'), '22538415');
    expect(_tableColumn(tester, 2), List.filled(8, '•'));
    expect(_tableColumn(tester, 3).first, '(1 − •) mod 10');
    _expectNowhere(tester, '90817263');
    handle.dispose();
  });

  testWidgets(
      'weak saved vectors: no notice would describe them, even revealed',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({_key: '00000000'});
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await _pump(tester);
    await tester.enterText(fieldById('pin_shift_pin'), '12345678');
    await _tap(tester, 'pin_shift_reveal');
    expect(_digits(tester, 'pin_shift_output'), '12345678');
    expect(byId('pin_shift_weak_zero'), findsNothing);
  });

  testWidgets(
      'replace: an empty field that can be revealed while typing; Cancel '
      'goes back; Save replaces', (tester) async {
    FlutterSecureStorage.setMockInitialValues({_key: '11111111'});
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await _pump(tester);
    final l = l10n(tester);

    await _tap(tester, 'pin_shift_vector_replace');
    expect(byId('pin_shift_vector_saved'), findsNothing);
    expect(fieldText(tester, 'pin_shift_vector'), isEmpty);
    expect(find.text(l.pinShiftVectorNewLabel), findsOneWidget);
    expect(find.text(l.pinShiftVectorReplaceNote), findsOneWidget);
    expect(byId('pin_shift_vector_eye'), findsOneWidget);
    expect(byId('pin_shift_vector_cancel'), findsOneWidget);
    expect(_enabled(tester, 'pin_shift_vector_save'), isFalse);
    expect(find.text(l.pinShiftVectorSaveReplace), findsOneWidget);
    // The length can change while replacing.
    expect(byId('pin_shift_len_locked'), findsNothing);
    await _tap(tester, 'pin_shift_len_4');
    expect(_length(tester), 4);

    // Cancel: back to the saved vector and its length; nothing written.
    await tester.enterText(fieldById('pin_shift_vector'), '3719');
    await tester.pump();
    await _tap(tester, 'pin_shift_vector_cancel');
    expect(byId('pin_shift_vector_saved'), findsOneWidget);
    expect(byId('pin_shift_vector'), findsNothing);
    expect(_length(tester), 8);
    expect((await _prefs())[PinPrefs.kShiftLength], 8);
    expect((await _keychain())[_key], '11111111');

    // Replace with a 4-digit vector, revealed while typing and used by the
    // result before it is saved.
    await _tap(tester, 'pin_shift_vector_replace');
    expect(fieldText(tester, 'pin_shift_vector'), isEmpty,
        reason: 'Cancel dropped what was typed');
    await _tap(tester, 'pin_shift_len_4');
    await tester.enterText(fieldById('pin_shift_vector'), '3719');
    await tester.pump();
    await _tap(tester, 'pin_shift_vector_eye');
    expect(_obscured(tester, 'pin_shift_vector'), isFalse);
    await tester.enterText(fieldById('pin_shift_pin'), '1234');
    await tester.pump();
    await _tap(tester, 'pin_shift_reveal');
    expect(find.text(l.pinShiftReveal), findsOneWidget);
    expect(_digits(tester, 'pin_shift_vector_row'), '3719');
    expect(_digits(tester, 'pin_shift_output'), '4943');

    await _tap(tester, 'pin_shift_vector_save');
    expect(find.text(l.pinShiftVectorReplacedSnack), findsOneWidget);
    expect((await _keychain())[_key], '3719');
    expect(find.text(l.pinShiftVectorSavedTitle(4)), findsOneWidget);
    expect(byId('pin_shift_vector_eye'), findsNothing);
    expect(_length(tester), 4);
    expect((await _prefs())[PinPrefs.kShiftLength], 4);
    // Still revealed: the PIN yes, the vector no longer.
    expect(_digits(tester, 'pin_shift_vector_row'), isEmpty);
    expect(_digits(tester, 'pin_shift_output'), '4943');
    expect(find.textContaining('3719'), findsNothing);
  });

  testWidgets('delete asks first; then the field and Save are back',
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({_key: '11111111'});
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await _pump(tester);
    final l = l10n(tester);

    await _tap(tester, 'pin_shift_vector_delete');
    await tester.pumpAndSettle();
    expect(find.text(l.pinShiftVectorDeleteTitle), findsOneWidget);
    expect(find.text(l.pinShiftVectorDeleteBody), findsOneWidget);
    await tester.tap(byId('pin_shift_vector_delete_cancel'));
    await tester.pumpAndSettle();
    expect(byId('pin_shift_vector_saved'), findsOneWidget);
    expect((await _keychain())[_key], '11111111');

    await _tap(tester, 'pin_shift_vector_delete');
    await tester.pumpAndSettle();
    await tester.tap(byId('pin_shift_vector_delete_confirm'));
    await tester.pumpAndSettle();
    expect((await _keychain()).containsKey(_key), isFalse);
    expect(find.text(l.pinShiftVectorDeletedSnack), findsOneWidget);
    expect(byId('pin_shift_vector_saved'), findsNothing);
    expect(fieldText(tester, 'pin_shift_vector'), isEmpty);
    expect(byId('pin_shift_vector_eye'), findsOneWidget);
    expect(byId('pin_shift_vector_save'), findsOneWidget);
    expect(find.text(l.pinShiftFillBoth(8)), findsOneWidget);
    expect(byId('pin_shift_len_locked'), findsNothing);
  });

  testWidgets('the saved vector fixes the length and the remembered pref',
      (tester) async {
    // A stale remembered length: the saved vector wins.
    setPinPrefs({PinPrefs.kShiftLength: 8});
    FlutterSecureStorage.setMockInitialValues({_key: '123456'});
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await _pump(tester);
    final l = l10n(tester);

    expect(_length(tester), 6);
    expect((await _prefs())[PinPrefs.kShiftLength], 6);
    expect(find.text(l.pinShiftVectorSavedTitle(6)), findsOneWidget);
    expect(byId('pin_shift_len_locked'), findsOneWidget);
    expect(find.text(l.pinShiftLengthSetBySaved), findsOneWidget);
    expect(_pillSelected(tester, 'pin_shift_len_6'), isTrue);
    expect(_enabled(tester, 'pin_shift_len_inc'), isFalse);
    expect(_enabled(tester, 'pin_shift_len_dec'), isFalse);
    await tester.tap(byId('pin_shift_len_4'), warnIfMissed: false);
    await tester.pump();
    expect(_length(tester), 6);
    expect((await _prefs())[PinPrefs.kShiftLength], 6);

    // 123456 + 123456 = 246802.
    await tester.enterText(fieldById('pin_shift_pin'), '123456');
    await tester.pump();
    expect(_digits(tester, 'pin_shift_output'), '246802');

    // Deleting unlocks it (and keeps 6 until the user picks another).
    await _tap(tester, 'pin_shift_vector_delete');
    await tester.pumpAndSettle();
    await tester.tap(byId('pin_shift_vector_delete_confirm'));
    await tester.pumpAndSettle();
    expect(byId('pin_shift_len_locked'), findsNothing);
    expect(_length(tester), 6);
    await _tap(tester, 'pin_shift_len_4');
    expect(_length(tester), 4);
  });

  testWidgets(
      'wipes drop the digits from memory, not the saved vector; restored '
      'after another tool, leaving the tab and a new ProviderScope',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    resetLifecycleOnTearDown(tester);
    final store = _CountingStore();
    final container = await _pump(tester, store: store);
    expect(store.loads, 1, reason: 'read when the tool opens');

    await tester.enterText(fieldById('pin_shift_vector'), '11111111');
    await tester.pump();
    await _tap(tester, 'pin_shift_vector_save');
    await tester.enterText(fieldById('pin_shift_pin'), '12345678');
    await tester.pump();
    expect(_digits(tester, 'pin_shift_output'), '23456789');

    // A full wipe (🚨): the PIN goes, the card still says "saved"; the
    // digits are read again only when the next PIN is typed.
    container.read(pinSessionProvider).wipe(reason: PinWipeReason.user);
    await tester.pump();
    expect(fieldText(tester, 'pin_shift_pin'), isEmpty);
    expect(byId('pin_shift_vector_saved'), findsOneWidget);
    expect(store.loads, 1);
    await tester.enterText(fieldById('pin_shift_pin'), '1234567');
    await tester.pump();
    expect(store.loads, 2);
    await tester.enterText(fieldById('pin_shift_pin'), '12345678');
    await tester.pump();
    expect(store.loads, 2, reason: 'once per wipe, not per keystroke');
    expect(_digits(tester, 'pin_shift_output'), '23456789');

    // Background and Clear drop them as well.
    setLifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    setLifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    expect(byId('pin_shift_vector_saved'), findsOneWidget);
    await tester.enterText(fieldById('pin_shift_pin'), '12345678');
    await tester.pump();
    expect(store.loads, 3);
    expect(_digits(tester, 'pin_shift_output'), '23456789');
    await _tap(tester, 'pin_shift_clear');
    expect(byId('pin_shift_vector_saved'), findsOneWidget);
    expect((await _keychain())[_key], '11111111');

    // Another tool and back.
    await _tap(tester, 'pin_tool_yubikey');
    expect(byId('pin_shift_view'), findsNothing);
    await _tap(tester, 'pin_tool_shift');
    expect(byId('pin_shift_vector_saved'), findsOneWidget);

    // Leaving the tab (wipe) and a new ProviderScope on the same keychain
    // and preferences (an app restart).
    container.read(pinSessionProvider).wipe(reason: PinWipeReason.left);
    await tester.pump();
    final prefs = await _prefs();
    await tester.pumpWidget(const SizedBox());
    SharedPreferences.setMockInitialValues(prefs);
    await _pump(tester);
    expect(byId('pin_shift_vector_saved'), findsOneWidget);
    expect(byId('pin_shift_vector_eye'), findsNothing);
    await tester.enterText(fieldById('pin_shift_pin'), '12345678');
    await tester.pump();
    expect(_digits(tester, 'pin_shift_output'), '23456789');
  });

  testWidgets(
      'an unreadable keychain: Retry, the field still works, no Save, '
      'nothing echoed', (tester) async {
    FlutterSecureStorage.setMockInitialValues({_key: '90817263'});
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    final keychain = _FlakyKeychain();
    await _pump(tester, store: SecureStorageService(storage: keychain));
    final l = l10n(tester);

    expect(byId('pin_shift_vector_read_error'), findsOneWidget);
    expect(find.text(l.pinShiftVectorReadError), findsOneWidget);
    expect(byId('pin_shift_vector_retry'), findsOneWidget);
    expect(byId('pin_shift_vector_saved'), findsNothing);
    expect(byId('pin_shift_vector_save'), findsNothing);
    expect(find.textContaining('unreadable'), findsNothing);
    expect(find.textContaining('keystore'), findsNothing);
    // The vector can still be typed by hand.
    await tester.enterText(fieldById('pin_shift_pin'), '12345678');
    await tester.enterText(fieldById('pin_shift_vector'), '11111111');
    await tester.pump();
    expect(_digits(tester, 'pin_shift_output'), '23456789');

    // Still failing: still the error.
    await _tap(tester, 'pin_shift_vector_retry');
    expect(byId('pin_shift_vector_read_error'), findsOneWidget);

    keychain.failing = false;
    await _tap(tester, 'pin_shift_vector_retry');
    expect(byId('pin_shift_vector_read_error'), findsNothing);
    expect(byId('pin_shift_vector_saved'), findsOneWidget);
    expect(_length(tester), 8);
    // The vector typed meanwhile is gone; the saved one is used.
    expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        '12345678');
    expect(_digits(tester, 'pin_shift_output'), '02152831');
    expect(find.textContaining('90817263'), findsNothing);
    expect(find.textContaining('11111111'), findsNothing);
  });
}
