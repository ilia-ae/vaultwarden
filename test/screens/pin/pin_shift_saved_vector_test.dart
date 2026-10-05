// PIN Shift: several named vectors (P4) — saved in the app (encrypted with
// the account key, never shown again), chosen with one tap; experimental
// vectors read from the Bitwarden vault (P5).
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_approver/screens/pin/pin_prefs.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';
import 'package:vault_approver/services/crypto_service.dart';
import 'package:vault_approver/services/encrypted_shift_vector_store.dart';
import 'package:vault_approver/services/secure_storage_service.dart';
import 'package:vault_approver/services/shift_vectors.dart';

import 'pin_harness.dart';

/// An in-memory store that counts loads and can fail on demand.
class _Store implements ShiftVectorStore {
  _Store([List<ShiftVector> initial = const []]) : _vectors = List.of(initial);

  List<ShiftVector> _vectors;
  int loads = 0;
  int discards = 0;
  ShiftVectorFailure? failLoad;
  bool failSave = false;

  List<ShiftVector> get saved => List.unmodifiable(_vectors);

  @override
  Future<List<ShiftVector>> load() async {
    loads++;
    final f = failLoad;
    if (f != null) throw ShiftVectorException(f);
    return List.of(_vectors);
  }

  @override
  Future<void> save(List<ShiftVector> vectors) async {
    if (failSave) {
      throw const ShiftVectorException(ShiftVectorFailure.unavailable);
    }
    _vectors = List.of(vectors);
  }

  @override
  Future<void> discard() async {
    discards++;
    failLoad = null;
    _vectors = [];
  }
}

class _Source implements ShiftVectorSource {
  _Source(this.vectors);

  List<ShiftVector> vectors;
  int fetches = 0;
  bool fail = false;

  @override
  Future<List<ShiftVector>> fetch() async {
    fetches++;
    if (fail) throw Exception('network');
    return List.of(vectors);
  }
}

const _ledger1 = ShiftVector(id: 'l1', name: 'Ledger 1', vector: '11111111');
const _ledger2 = ShiftVector(id: 'l2', name: 'Ledger 2', vector: '123456');
const _vaultStax = ShiftVector(
    id: 'vault:c1', name: 'Ledger Stax', vector: '90817263', fromVault: true);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  ShiftVectorStore? store,
  ShiftVectorSource? source,
}) async {
  final container = await pumpPin(tester, overrides: [
    shiftVectorStoreProvider.overrideWithValue(store),
    shiftVectorSourceProvider.overrideWithValue(source),
  ]);
  await tester.pump();
  await tester.pump();
  return container;
}

Future<Map<String, Object>> _prefs() async {
  final prefs = await SharedPreferences.getInstance();
  return {for (final k in prefs.getKeys()) k: prefs.get(k)!};
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

bool _selected(WidgetTester tester, String id) =>
    tester.widget<Semantics>(byId(id)).properties.selected ?? false;

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

Future<void> _enter(WidgetTester tester, String id, String text) async {
  await tester.ensureVisible(byId(id));
  await tester.enterText(fieldById(id), text);
  await tester.pump();
}

/// Types [vector] by hand, opens the form and saves it as [name].
Future<void> _saveByHand(
    WidgetTester tester, String name, String vector) async {
  await _enter(tester, 'pin_shift_vector', vector);
  await _tap(tester, 'pin_shift_vector_save');
  await _enter(tester, 'pin_shift_name', name);
  await _tap(tester, 'pin_shift_vector_save');
  await tester.pump();
}

/// Every run of 3+ consecutive digits of [vector], plain and spaced.
List<String> _spellings(String vector) => [
      for (var len = 3; len <= vector.length; len++)
        for (var i = 0; i + len <= vector.length; i++) ...[
          vector.substring(i, i + len),
          vector.substring(i, i + len).split('').join(' '),
        ],
    ];

/// Fails if any widget text or semantics spells [vector].
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

  testWidgets('no store wired: no chooser, no Save, the tool works as before',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    expect(byId('pin_shift_vector'), findsOneWidget);
    expect(byId('pin_shift_pick_manual'), findsNothing);
    expect(byId('pin_shift_vector_save'), findsNothing);
    expect(byId('pin_shift_vault_read'), findsNothing);
  });

  testWidgets(
      'save by hand under a name: chosen at once, masked, the result is '
      'named; only the PIN is typed from then on', (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    final store = _Store();
    final container = await _pump(tester, store: store);
    final l = l10n(tester);

    // Nothing saved: no chooser yet, the field and a disabled Save.
    expect(byId('pin_shift_pick_manual'), findsNothing);
    expect(_enabled(tester, 'pin_shift_vector_save'), isFalse);
    await _enter(tester, 'pin_shift_vector', '1111');
    expect(_enabled(tester, 'pin_shift_vector_save'), isFalse);
    await _enter(tester, 'pin_shift_vector', '11111111');
    expect(_enabled(tester, 'pin_shift_vector_save'), isTrue);

    // The form: a name (focused), the typed vector kept and revealable.
    await _tap(tester, 'pin_shift_vector_save');
    expect(find.text('2 · ${l.pinShiftFormNew}'), findsOneWidget);
    expect(byId('pin_shift_name'), findsOneWidget);
    expect(fieldText(tester, 'pin_shift_vector'), '11111111');
    expect(_enabled(tester, 'pin_shift_vector_save'), isFalse,
        reason: 'no name yet');
    await _tap(tester, 'pin_shift_vector_eye');
    expect(_obscured(tester, 'pin_shift_vector'), isFalse);
    await _enter(tester, 'pin_shift_name', '  Ledger   1 ');
    expect(_enabled(tester, 'pin_shift_vector_save'), isTrue);
    await _tap(tester, 'pin_shift_vector_save');
    await tester.pump();
    expect(find.text(l.pinShiftVectorSavedSnack), findsOneWidget);

    final saved = store.saved.single;
    expect(saved.name, 'Ledger 1', reason: 'normalized');
    expect(saved.vector, '11111111');
    expect((await _prefs())[PinPrefs.kShiftSelected], saved.id);
    for (final v in (await _prefs()).values) {
      expect('$v', isNot(contains('11111111')));
      expect('$v', isNot(contains('Ledger')));
    }

    // Chosen: a pill per vector, "By hand" and "Add"; masked card below the
    // result; the result is named.
    expect(_selected(tester, 'pin_shift_pick_0'), isTrue);
    expect(byId('pin_shift_pick_manual'), findsOneWidget);
    expect(byId('pin_shift_add'), findsOneWidget);
    expect(
        find.text(l.pinShiftVectorNamedTitle('Ledger 1', 8)), findsOneWidget);
    expect(_texts(tester, 'pin_shift_vector_saved'), contains('•|•|•|•'));
    expect(byId('pin_shift_vector'), findsNothing);
    expect(byId('pin_shift_vector_eye'), findsNothing);
    expect(byId('pin_shift_vector_edit'), findsOneWidget);
    expect(byId('pin_shift_vector_delete'), findsOneWidget);
    expect(find.text('2 · ${l.pinShiftSectionResultFor('Ledger 1')}'),
        findsOneWidget);
    expect(container.read(pinSessionProvider).hasContent, isFalse,
        reason: 'the typed vector and the name left their fields');

    await _enter(tester, 'pin_shift_pin', '12345678');
    expect(_digits(tester, 'pin_shift_output'), '23456789');
    expect(find.text(l.pinShiftHiddenNoteSaved), findsOneWidget);
    await _tap(tester, 'pin_shift_decode');
    await _enter(tester, 'pin_shift_pin', '23456789');
    expect(_digits(tester, 'pin_shift_output'), '12345678');
  });

  testWidgets(
      'several vectors: one tap switches the result for the same PIN, the '
      'length follows the vector, the choice is remembered', (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    final store = _Store([_ledger1, _ledger2]);
    await _pump(tester, store: store);
    final l = l10n(tester);

    // First visit: the first saved vector.
    expect(_selected(tester, 'pin_shift_pick_0'), isTrue);
    expect(_length(tester), 8);
    expect(byId('pin_shift_len_locked'), findsOneWidget);
    await _enter(tester, 'pin_shift_pin', '12345678');
    expect(_digits(tester, 'pin_shift_output'), '23456789');

    await _tap(tester, 'pin_shift_pick_1');
    expect(_selected(tester, 'pin_shift_pick_1'), isTrue);
    expect(_length(tester), 6);
    expect(find.text('2 · ${l.pinShiftSectionResultFor('Ledger 2')}'),
        findsOneWidget);
    await _enter(tester, 'pin_shift_pin', '123456');
    expect(_digits(tester, 'pin_shift_output'), '246802');
    expect((await _prefs())[PinPrefs.kShiftSelected], 'l2');

    // "By hand": the field again, before the result; length unlocked.
    await _tap(tester, 'pin_shift_pick_manual');
    expect(byId('pin_shift_vector'), findsOneWidget);
    expect(byId('pin_shift_len_locked'), findsNothing);
    expect(find.text('2 · ${l.pinShiftSectionVector}'), findsOneWidget);
    expect((await _prefs())[PinPrefs.kShiftSelected], PinPrefs.shiftManual);

    // A new ProviderScope (app restart): "By hand" is remembered.
    final prefs = await _prefs();
    await tester.pumpWidget(const SizedBox());
    SharedPreferences.setMockInitialValues(prefs);
    await _pump(tester, store: store);
    expect(_selected(tester, 'pin_shift_pick_manual'), isTrue);
    await _tap(tester, 'pin_shift_pick_1');
    final prefs2 = await _prefs();
    await tester.pumpWidget(const SizedBox());
    SharedPreferences.setMockInitialValues(prefs2);
    await _pump(tester, store: store);
    expect(_selected(tester, 'pin_shift_pick_1'), isTrue);
  });

  testWidgets(
      'Add with Generate: random digits of the chosen length, shown once with '
      'a warning; names must be unique', (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    final store = _Store([_ledger1]);
    await _pump(tester, store: store);
    final l = l10n(tester);

    await _tap(tester, 'pin_shift_add');
    expect(find.text('2 · ${l.pinShiftFormNew}'), findsOneWidget);
    expect(byId('pin_shift_len_locked'), findsNothing,
        reason: 'the form picks its own length');
    await _tap(tester, 'pin_shift_len_6');
    await _tap(tester, 'pin_shift_generate');
    final generated = fieldText(tester, 'pin_shift_vector');
    expect(generated, matches(RegExp(r'^[0-9]{6}$')));
    expect(_obscured(tester, 'pin_shift_vector'), isFalse);
    expect(find.text(l.pinShiftGeneratedNote), findsOneWidget);

    // Duplicate (any case / spacing): error, Save off.
    await _enter(tester, 'pin_shift_name', ' ledger  1');
    expect(find.text(l.pinShiftNameTaken), findsOneWidget);
    expect(_enabled(tester, 'pin_shift_vector_save'), isFalse);
    // Names are capped.
    await _enter(tester, 'pin_shift_name', 'x' * 60);
    expect(
        fieldText(tester, 'pin_shift_name').length, kMaxShiftVectorNameLength);
    await _enter(tester, 'pin_shift_name', 'Ledger 2');
    expect(find.text(l.pinShiftNameTaken), findsNothing);
    await _tap(tester, 'pin_shift_vector_save');
    await tester.pump();

    expect(store.saved.map((v) => v.name), ['Ledger 1', 'Ledger 2']);
    expect(store.saved.last.vector, generated);
    expect(_selected(tester, 'pin_shift_pick_1'), isTrue);
    expect(find.text(l.pinShiftGeneratedNote), findsNothing);
    _expectNowhere(tester, generated);
  });

  testWidgets(
      'a saved vector is never shown: Reveal shows only the PIN, masked '
      'breakdown, no digits in any text or semantics', (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    final handle = tester.ensureSemantics();
    await _pump(tester,
        store: _Store([
          const ShiftVector(id: 'x', name: 'Ledger 1', vector: '90817263')
        ]));
    final l = l10n(tester);
    expect(find.bySemanticsLabel(l.pinShiftVectorNamedSemantics('Ledger 1', 8)),
        findsOneWidget);
    _expectNowhere(tester, '90817263');

    await _enter(tester, 'pin_shift_pin', '12345678');
    expect(_digits(tester, 'pin_shift_output'), '02152831');
    await _tap(tester, 'pin_shift_reveal');
    expect(_digits(tester, 'pin_shift_input_row'), '12345678');
    expect(_digits(tester, 'pin_shift_vector_row'), isEmpty);
    await _tap(tester, 'pin_shift_breakdown');
    await tester.pumpAndSettle();
    expect(byId('pin_shift_weak_zero'), findsNothing);
    _expectNowhere(tester, '90817263');
    handle.dispose();
  });

  testWidgets(
      'Edit: rename only keeps the vector; a new vector replaces it; Cancel '
      'goes back', (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    final store = _Store([_ledger1, _ledger2]);
    await _pump(tester, store: store);
    final l = l10n(tester);
    await _enter(tester, 'pin_shift_pin', '12345678');

    await _tap(tester, 'pin_shift_vector_edit');
    expect(find.text('2 · ${l.pinShiftFormEdit('Ledger 1')}'), findsOneWidget);
    expect(fieldText(tester, 'pin_shift_name'), 'Ledger 1');
    expect(fieldText(tester, 'pin_shift_vector'), isEmpty,
        reason: 'the saved vector is never put back in a field');
    expect(find.text(l.pinShiftVectorKeepHelp), findsOneWidget);
    expect(_enabled(tester, 'pin_shift_vector_save'), isTrue);

    // Cancel: back to the chosen vector, nothing written.
    await _tap(tester, 'pin_shift_vector_cancel');
    expect(byId('pin_shift_vector_saved'), findsOneWidget);
    expect(store.saved, [_ledger1, _ledger2]);

    // Rename only.
    await _tap(tester, 'pin_shift_vector_edit');
    await _enter(tester, 'pin_shift_name', 'Ledger Nano');
    await _tap(tester, 'pin_shift_vector_save');
    await tester.pump();
    expect(find.text(l.pinShiftVectorUpdatedSnack), findsOneWidget);
    expect(store.saved.first.name, 'Ledger Nano');
    expect(store.saved.first.vector, '11111111');
    expect(store.saved.first.id, 'l1');
    await _enter(tester, 'pin_shift_pin', '12345678');
    expect(_digits(tester, 'pin_shift_output'), '23456789');

    // A new vector (another length is allowed).
    await _tap(tester, 'pin_shift_vector_edit');
    await _tap(tester, 'pin_shift_len_4');
    await _enter(tester, 'pin_shift_vector', '3719');
    await _tap(tester, 'pin_shift_vector_save');
    await tester.pump();
    expect(store.saved.first.vector, '3719');
    expect(_length(tester), 4);
    await _enter(tester, 'pin_shift_pin', '1234');
    expect(_digits(tester, 'pin_shift_output'), '4943');
  });

  testWidgets('Delete asks first (named); then the next vector or by hand',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    final store = _Store([_ledger1, _ledger2]);
    await _pump(tester, store: store);
    final l = l10n(tester);

    await _tap(tester, 'pin_shift_vector_delete');
    await tester.pumpAndSettle();
    expect(find.text(l.pinShiftVectorDeleteNamedTitle('Ledger 1')),
        findsOneWidget);
    await tester.tap(byId('pin_shift_vector_delete_cancel'));
    await tester.pumpAndSettle();
    expect(store.saved, hasLength(2));

    await _tap(tester, 'pin_shift_vector_delete');
    await tester.pumpAndSettle();
    await tester.tap(byId('pin_shift_vector_delete_confirm'));
    await tester.pumpAndSettle();
    expect(store.saved, [_ledger2]);
    expect(_selected(tester, 'pin_shift_pick_0'), isTrue);
    expect(_length(tester), 6);

    await _tap(tester, 'pin_shift_vector_delete');
    await tester.pumpAndSettle();
    await tester.tap(byId('pin_shift_vector_delete_confirm'));
    await tester.pumpAndSettle();
    expect(store.saved, isEmpty);
    expect(byId('pin_shift_pick_manual'), findsNothing,
        reason: 'nothing left to choose');
    expect(byId('pin_shift_vector'), findsOneWidget);
    expect(byId('pin_shift_len_locked'), findsNothing);
  });

  testWidgets(
      'wipes drop the digits and an open form, not the saved vectors; read '
      'again once on the next PIN', (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    resetLifecycleOnTearDown(tester);
    final store = _Store([_ledger1]);
    final container = await _pump(tester, store: store);
    expect(store.loads, 1);
    await _enter(tester, 'pin_shift_pin', '12345678');
    expect(_digits(tester, 'pin_shift_output'), '23456789');

    container.read(pinSessionProvider).wipe(reason: PinWipeReason.user);
    await tester.pump();
    expect(fieldText(tester, 'pin_shift_pin'), isEmpty);
    expect(byId('pin_shift_vector_saved'), findsOneWidget);
    expect(store.loads, 1);
    await _enter(tester, 'pin_shift_pin', '1234567');
    await _enter(tester, 'pin_shift_pin', '12345678');
    expect(store.loads, 2, reason: 'once per wipe, not per keystroke');
    expect(_digits(tester, 'pin_shift_output'), '23456789');

    // An open form goes with a wipe (background).
    await _tap(tester, 'pin_shift_add');
    await _enter(tester, 'pin_shift_name', 'Draft');
    await _enter(tester, 'pin_shift_vector', '5555');
    setLifecycle(tester, AppLifecycleState.paused);
    await tester.pump();
    setLifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    expect(byId('pin_shift_name'), findsNothing);
    expect(byId('pin_shift_vector_saved'), findsOneWidget);
    expect(container.read(pinSessionProvider).hasContent, isFalse);
    expect(store.saved, [_ledger1]);
  });

  testWidgets(
      'an unreadable keychain: Retry; typing by hand still works, no Save',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    final store = _Store([_ledger1])..failLoad = ShiftVectorFailure.unavailable;
    await _pump(tester, store: store);
    final l = l10n(tester);

    expect(find.text(l.pinShiftVectorReadError), findsOneWidget);
    expect(byId('pin_shift_vector_save'), findsNothing);
    expect(byId('pin_shift_add'), findsNothing);
    await _enter(tester, 'pin_shift_pin', '12345678');
    await _enter(tester, 'pin_shift_vector', '11111111');
    expect(_digits(tester, 'pin_shift_output'), '23456789');

    await _tap(tester, 'pin_shift_vector_retry');
    expect(find.text(l.pinShiftVectorReadError), findsOneWidget);
    store.failLoad = null;
    await _tap(tester, 'pin_shift_vector_retry');
    expect(find.text(l.pinShiftVectorReadError), findsNothing);
    expect(_selected(tester, 'pin_shift_pick_0'), isTrue);
  });

  for (final failure in [
    ShiftVectorFailure.otherAccount,
    ShiftVectorFailure.corrupt
  ]) {
    testWidgets('saved with another key / damaged ($failure): delete them',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      final store = _Store([_ledger1])..failLoad = failure;
      await _pump(tester, store: store);
      final l = l10n(tester);

      expect(
          find.text(failure == ShiftVectorFailure.corrupt
              ? l.pinShiftVectorsCorrupt
              : l.pinShiftVectorsOtherAccount),
          findsOneWidget);
      expect(byId('pin_shift_vector_save'), findsNothing);
      await _tap(tester, 'pin_shift_vectors_discard');
      await tester.pumpAndSettle();
      expect(find.text(l.pinShiftVectorsDiscardTitle), findsOneWidget);
      await tester.tap(byId('pin_shift_vectors_discard_confirm'));
      await tester.pumpAndSettle();
      expect(store.discards, 1);
      expect(byId('pin_shift_vectors_foreign'), findsNothing);
      // New ones can be saved again.
      await _saveByHand(tester, 'Ledger 9', '99999999');
      expect(store.saved.single.name, 'Ledger 9');
    });
  }

  testWidgets('a failed save keeps the form and says so', (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    final store = _Store()..failSave = true;
    await _pump(tester, store: store);
    final l = l10n(tester);
    await _saveByHand(tester, 'Ledger 1', '11111111');
    expect(find.text(l.pinShiftVectorSaveError), findsOneWidget);
    expect(byId('pin_shift_name'), findsOneWidget);
    expect(store.saved, isEmpty);
  });

  testWidgets('full: no Add, no Save, a note', (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    final many = [
      for (var i = 0; i < kMaxShiftVectors; i++)
        ShiftVector(id: 'v$i', name: 'V $i', vector: '1234'),
    ];
    await _pump(tester, store: _Store(many));
    final l = l10n(tester);
    expect(byId('pin_shift_add'), findsNothing);
    expect(find.text(l.pinShiftVectorsFull(kMaxShiftVectors)), findsOneWidget);
    await _tap(tester, 'pin_shift_pick_manual');
    expect(byId('pin_shift_vector_save'), findsNothing);
  });

  group('experimental: vectors from the Bitwarden vault (P5)', () {
    testWidgets('off by default: no vault pills, nothing fetched',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      final source = _Source([_vaultStax]);
      await _pump(tester, store: _Store([_ledger1]), source: source);
      await tester.pump();
      expect(byId('pin_shift_vault_read'), findsOneWidget);
      expect(byId('pin_shift_pick_vault_0'), findsNothing);
      expect(source.fetches, 0);
    });

    testWidgets(
        'on: vault pills with their source, masked, "Save on this device"; '
        'off again drops them', (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      final handle = tester.ensureSemantics();
      final store = _Store([_ledger1]);
      final source = _Source([_vaultStax]);
      await _pump(tester, store: store, source: source);
      final l = l10n(tester);

      await _tap(tester, 'pin_shift_vault_read');
      await tester.pump();
      expect(source.fetches, 1);
      expect((await _prefs())[PinPrefs.kShiftVaultRead], true);
      expect(byId('pin_shift_pick_vault_0'), findsOneWidget);
      expect(find.bySemanticsLabel(l.pinShiftVaultChipSemantics('Ledger Stax')),
          findsOneWidget);

      await _tap(tester, 'pin_shift_pick_vault_0');
      expect(byId('pin_shift_vector_vault'), findsOneWidget);
      expect(find.text(l.pinShiftVaultEntryHelp), findsOneWidget);
      expect(byId('pin_shift_vector_edit'), findsNothing);
      await _enter(tester, 'pin_shift_pin', '12345678');
      expect(_digits(tester, 'pin_shift_output'), '02152831');
      _expectNowhere(tester, '90817263');

      await _tap(tester, 'pin_shift_vector_keep');
      await tester.pump();
      expect(store.saved.map((v) => (v.name, v.vector, v.fromVault)), [
        ('Ledger 1', '11111111', false),
        ('Ledger Stax', '90817263', false),
      ]);
      expect(_selected(tester, 'pin_shift_pick_1'), isTrue);

      await _tap(tester, 'pin_shift_pick_vault_0');
      await _tap(tester, 'pin_shift_vault_read');
      expect(byId('pin_shift_pick_vault_0'), findsNothing);
      expect(_selected(tester, 'pin_shift_pick_0'), isTrue,
          reason: 'a vault choice falls back to the first saved vector');
      handle.dispose();
    });

    testWidgets('error with Retry; empty vault says so', (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      setPinPrefs({PinPrefs.kShiftVaultRead: true});
      final source = _Source([])..fail = true;
      await _pump(tester, store: _Store(), source: source);
      final l = l10n(tester);
      expect(find.text(l.pinShiftVaultError), findsOneWidget);
      source.fail = false;
      await _tap(tester, 'pin_shift_vault_retry');
      await tester.pump();
      expect(find.text(l.pinShiftVaultEmpty), findsOneWidget);
    });

    testWidgets('a remembered vault choice is restored once the vault answers',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      setPinPrefs({
        PinPrefs.kShiftVaultRead: true,
        PinPrefs.kShiftSelected: 'vault:c1',
      });
      await _pump(tester,
          store: _Store([_ledger1]), source: _Source([_vaultStax]));
      await tester.pump();
      expect(_selected(tester, 'pin_shift_pick_vault_0'), isTrue);
    });
  });

  group('with the real encrypted store over the device keychain', () {
    final crypto = CryptoService(runKdfInIsolate: false);
    final key = Uint8List.fromList(List.generate(64, (i) => i * 7 % 256));
    final otherKey = Uint8List.fromList(List.generate(64, (i) => i * 11 % 256));

    EncryptedShiftVectorStore storeFor(Uint8List key) =>
        EncryptedShiftVectorStore(
          storage: SecureStorageService(),
          crypto: crypto,
          userKey: () => key,
        );

    Future<Map<String, String>> keychain() => const FlutterSecureStorage(
          aOptions: SecureStorageService.androidOptions,
          iOptions: SecureStorageService.iosOptions,
        ).readAll();

    testWidgets(
        'saved through the UI as one encrypted item; same account reopens it, '
        'another account cannot', (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await _pump(tester, store: storeFor(key));
      await _saveByHand(tester, 'Ledger 1', '11111111');

      final items = await keychain();
      expect(items.keys, [SecureStorageService.keyPinShiftVectors]);
      final blob = items.values.single;
      expect(blob, startsWith('2.'));
      expect(blob, isNot(contains('11111111')));
      expect(blob, isNot(contains('Ledger')));

      final prefs = await _prefs();
      await tester.pumpWidget(const SizedBox());
      SharedPreferences.setMockInitialValues(prefs);
      await _pump(tester, store: storeFor(key));
      expect(_selected(tester, 'pin_shift_pick_0'), isTrue);
      await _enter(tester, 'pin_shift_pin', '12345678');
      expect(_digits(tester, 'pin_shift_output'), '23456789');

      await tester.pumpWidget(const SizedBox());
      SharedPreferences.setMockInitialValues(prefs);
      await _pump(tester, store: storeFor(otherKey));
      expect(byId('pin_shift_vectors_foreign'), findsOneWidget);
      expect(byId('pin_shift_pick_0'), findsNothing);
    });

    testWidgets('the 1.1.0 single vector shows up as "PIN Shift", chosen',
        (tester) async {
      FlutterSecureStorage.setMockInitialValues(
          {SecureStorageService.keyPinShiftVector: '90817263'});
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await _pump(tester, store: storeFor(key));
      final l = l10n(tester);
      expect(_selected(tester, 'pin_shift_pick_0'), isTrue);
      expect(find.text(l.pinShiftVectorNamedTitle('PIN Shift', 8)),
          findsOneWidget);
      await _enter(tester, 'pin_shift_pin', '12345678');
      expect(_digits(tester, 'pin_shift_output'), '02152831');
      expect(
          (await keychain())
              .containsKey(SecureStorageService.keyPinShiftVector),
          isFalse);
    });
  });
}
