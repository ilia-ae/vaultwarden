import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/services/crypto_service.dart';
import 'package:vault_approver/services/shift_vectors.dart';
import 'package:vault_approver/services/vault_api.dart';
import 'package:vault_approver/services/vault_shift_vector_source.dart';

/// Experimental vault reader (P5): items with a "PIN Shift" custom field,
/// decrypted on the device like the official clients do.

final _crypto = CryptoService(runKdfInIsolate: false);

Uint8List _key(int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(64, (_) => r.nextInt(256)));
}

String _enc(String text, Uint8List key) => _crypto
    .encryptSymmetric(Uint8List.fromList(utf8.encode(text)), key)
    .encode();

/// A GET /api/ciphers item (camelCase, as Vaultwarden ≥ 1.27 and bitwarden.com
/// send it). [itemKey]: the item has its own key (newer clients).
Map<String, Object?> _cipher(
  Uint8List userKey, {
  required String id,
  required String name,
  Map<String, String> fields = const {},
  Uint8List? itemKey,
  String? organizationId,
  String? deletedDate,
}) {
  final k = itemKey ?? userKey;
  return {
    'object': 'cipherDetails',
    'id': id,
    'type': 1,
    'organizationId': organizationId,
    'deletedDate': deletedDate,
    // The item key is the raw 64 bytes, encrypted with the user key.
    'key': itemKey == null
        ? null
        : _crypto.encryptSymmetric(itemKey, userKey).encode(),
    'name': _enc(name, k),
    'fields': [
      for (final MapEntry(key: n, value: v) in fields.entries)
        {'type': 1, 'name': _enc(n, k), 'value': _enc(v, k)},
    ],
  };
}

class _FakeApi implements VaultApiService {
  _FakeApi(this.items);

  final List<Object?> items;
  int calls = 0;

  @override
  Future<List<Object?>> getCiphers() async {
    calls++;
    return items;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final userKey = _key(1);

  List<ShiftVector> read(List<Object?> ciphers) =>
      shiftVectorsFromCiphers(ciphers, userKey, _crypto);

  test('items with a "PIN Shift" field, named after the item, sorted', () {
    final out = read([
      _cipher(userKey,
          id: 'c2', name: 'Ledger Stax', fields: {'PIN Shift': '13572468'}),
      _cipher(userKey,
          id: 'c1',
          name: 'Ledger Nano X',
          fields: {'note': 'x', 'PIN Shift': '90817263'}),
      _cipher(userKey, id: 'c3', name: 'Mail', fields: {'note': '1234'}),
      _cipher(userKey, id: 'c4', name: 'No fields'),
    ]);
    expect([
      for (final v in out) (v.id, v.name, v.vector, v.fromVault)
    ], [
      ('vault:c1', 'Ledger Nano X', '90817263', true),
      ('vault:c2', 'Ledger Stax', '13572468', true),
    ]);
  });

  test('field name: case, spaces, "_" and "-" do not matter', () {
    for (final name in [
      'PIN Shift',
      'pin_shift',
      'PINSHIFT',
      'Pin-Shift',
      ' pin shift '
    ]) {
      final out = read([
        _cipher(userKey, id: 'c', name: 'L', fields: {name: '1234'}),
      ]);
      expect(out.single.vector, '1234', reason: name);
    }
    expect(
        read([
          _cipher(userKey, id: 'c', name: 'L', fields: {'PIN Shifts': '1234'})
        ]),
        isEmpty);
  });

  test('the value may be grouped with spaces or dashes; else skipped', () {
    expect(
        read([
          _cipher(userKey,
              id: 'c', name: 'L', fields: {'PIN Shift': '9081 7263'})
        ]).single.vector,
        '90817263');
    expect(
        read([
          _cipher(userKey,
              id: 'c', name: 'L', fields: {'PIN Shift': '9081-7263'})
        ]).single.vector,
        '90817263');
    for (final bad in ['12ab', ' ', '12345678901234567', '١٢٣٤']) {
      expect(
          read([
            _cipher(userKey, id: 'c', name: 'L', fields: {'PIN Shift': bad})
          ]),
          isEmpty,
          reason: bad);
    }
  });

  test('an item with its own key', () {
    final out = read([
      _cipher(userKey,
          id: 'k',
          name: 'Ledger 3',
          itemKey: _key(7),
          fields: {'PIN Shift': '5555'}),
    ]);
    expect(out.single.name, 'Ledger 3');
    expect(out.single.vector, '5555');
  });

  test('organization items, trash and undecryptable items are skipped', () {
    final out = read([
      _cipher(userKey,
          id: 'o',
          name: 'Org',
          organizationId: 'org-1',
          fields: {'PIN Shift': '1111'}),
      _cipher(userKey,
          id: 't',
          name: 'Trash',
          deletedDate: '2026-01-01T00:00:00Z',
          fields: {'PIN Shift': '2222'}),
      // Encrypted with someone else's key.
      _cipher(_key(99), id: 'x', name: 'Other', fields: {'PIN Shift': '3333'}),
      {'id': 'y', 'name': 'not-an-encstring', 'fields': 'nope'},
      'not a map',
      null,
      _cipher(userKey, id: 'ok', name: 'Ok', fields: {'PIN Shift': '4444'}),
    ]);
    expect([for (final v in out) v.id], ['vault:ok']);
  });

  test('PascalCase items (older Vaultwarden) are read too', () {
    final c = _cipher(userKey,
        id: 'p', name: 'Pascal', fields: {'PIN Shift': '6789'});
    final pascal = {
      'Id': c['id'],
      'OrganizationId': null,
      'DeletedDate': null,
      'Key': null,
      'Name': c['name'],
      'Fields': [
        for (final f in c['fields']! as List)
          {
            'Type': 1,
            'Name': (f as Map)['name'],
            'Value': f['value'],
          },
      ],
    };
    expect(read([pascal]).single.name, 'Pascal');
  });

  test('a nameless item is called "PIN Shift"', () {
    final c =
        _cipher(userKey, id: 'n', name: '   ', fields: {'PIN Shift': '12'});
    expect(read([c]).single.name, 'PIN Shift');
  });

  group('fetch', () {
    test('reads the ciphers once and decrypts with a copy of the key',
        () async {
      final api = _FakeApi([
        _cipher(userKey, id: 'c', name: 'L', fields: {'PIN Shift': '1234'}),
      ]);
      final live = Uint8List.fromList(userKey);
      final source = VaultShiftVectorSource(
          api: api, crypto: _crypto, userKey: () => live);
      expect((await source.fetch()).single.vector, '1234');
      expect(api.calls, 1);
      expect(live, userKey, reason: 'the live key is left as it was');
    });

    test('locked: throws locked', () async {
      final source = VaultShiftVectorSource(
          api: _FakeApi([]), crypto: _crypto, userKey: () => null);
      await expectLater(
        source.fetch(),
        throwsA(isA<ShiftVectorException>()
            .having((e) => e.failure, 'failure', ShiftVectorFailure.locked)),
      );
    });
  });
}
