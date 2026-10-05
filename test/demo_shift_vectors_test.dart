import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/demo_fixtures.dart';
import 'package:vault_approver/services/shift_vectors.dart';

/// P3: in a demo, PIN Shift's saved vectors live in memory for that demo
/// only (never the device keychain), and the vault reader is not offered.
class _RealStore extends InMemoryShiftVectorStore {}

class _RealSource implements ShiftVectorSource {
  @override
  Future<List<ShiftVector>> fetch() async => const [];
}

void main() {
  test('runtime demo: an in-memory store per demo, no vault reader', () async {
    final root = ProviderContainer(overrides: [
      // What main() wires for the real app.
      shiftVectorStoreProvider.overrideWithValue(_RealStore()),
      shiftVectorSourceProvider.overrideWithValue(_RealSource()),
    ]);
    addTearDown(root.dispose);

    ShiftVectorStore openDemo() {
      final demo =
          ProviderContainer(parent: root, overrides: runtimeDemoOverrides());
      addTearDown(demo.dispose);
      expect(demo.read(shiftVectorSourceProvider), isNull);
      final store = demo.read(shiftVectorStoreProvider);
      expect(store, isA<InMemoryShiftVectorStore>());
      expect(store, isNot(isA<_RealStore>()));
      return store!;
    }

    final first = openDemo();
    await first
        .save(const [ShiftVector(id: 'd', name: 'Demo', vector: '1234')]);
    expect(await first.load(), hasLength(1));
    // The next demo starts empty; the real store is untouched.
    expect(await openDemo().load(), isEmpty);
    expect(await root.read(shiftVectorStoreProvider)!.load(), isEmpty);
  });

  test('InMemoryShiftVectorStore: save, load, discard', () async {
    final store = InMemoryShiftVectorStore();
    expect(await store.load(), isEmpty);
    const v = ShiftVector(id: 'a', name: 'A', vector: '12');
    await store.save(const [v]);
    final loaded = await store.load();
    expect(loaded.single.id, 'a');
    loaded.clear(); // a copy
    expect(await store.load(), hasLength(1));
    await store.discard();
    expect(await store.load(), isEmpty);
  });

  test('ShiftVector never prints its digits', () {
    const v = ShiftVector(id: 'a', name: 'Ledger', vector: '90817263');
    expect('$v', isNot(contains('90817263')));
    expect('$v', isNot(contains('Ledger')));
  });

  test('names: normalized, compared case-insensitively, made unique', () {
    expect(normalizeShiftVectorName('  Ledger \t 1 '), 'Ledger 1');
    expect(sameShiftVectorName('ledger  1', 'Ledger 1'), isTrue);
    const taken = [
      ShiftVector(id: 'a', name: 'PIN Shift', vector: '1'),
      ShiftVector(id: 'b', name: 'pin shift 2', vector: '2'),
    ];
    expect(uniqueShiftVectorName('PIN Shift', taken), 'PIN Shift 3');
    expect(uniqueShiftVectorName('Other', taken), 'Other');
    expect(newShiftVectorId(), matches(RegExp(r'^[0-9a-f]{16}$')));
    expect(newShiftVectorId(), isNot(newShiftVectorId()));
  });
}
