import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_approver/models/cipher_string.dart';
import 'package:vault_approver/services/crypto_service.dart';
import 'package:vault_approver/services/encrypted_shift_vector_store.dart';
import 'package:vault_approver/services/secure_storage_service.dart';
import 'package:vault_approver/services/shift_vectors.dart';

import '../providers/provider_fakes.dart';

/// PIN Shift's saved vectors at rest (P1, P2): encrypted with a subkey of
/// the account key, opened only by that account, migrated from 1.1.0.

const _setKey = SecureStorageService.keyPinShiftVectors;
const _legacyKey = SecureStorageService.keyPinShiftVector;

Uint8List _randomKey(int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(64, (_) => r.nextInt(256)));
}

Future<Map<String, String>> _keychain() => const FlutterSecureStorage(
      aOptions: SecureStorageService.androidOptions,
      iOptions: SecureStorageService.iosOptions,
    ).readAll();

const _ledger1 = ShiftVector(id: 'a1', name: 'Ledger 1', vector: '90817263');
const _ledger2 = ShiftVector(id: 'b2', name: 'Ledger 2', vector: '1357');

void main() {
  final crypto = CryptoService(runKdfInIsolate: false);
  late SecureStorageService storage;
  late Uint8List? userKey;
  late EncryptedShiftVectorStore store;

  EncryptedShiftVectorStore storeWith(Uint8List? Function() key) =>
      EncryptedShiftVectorStore(storage: storage, crypto: crypto, userKey: key);

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    storage = SecureStorageService();
    userKey = _randomKey(1);
    store = storeWith(() => userKey);
  });

  test('nothing saved: an empty list, nothing written', () async {
    expect(await store.load(), isEmpty);
    expect(await _keychain(), isEmpty);
  });

  test('save and load: one EncString item, no names or digits in clear',
      () async {
    await store.save([_ledger1, _ledger2]);
    final items = await _keychain();
    expect(items.keys, [_setKey]);
    final blob = items[_setKey]!;
    expect(blob, startsWith('2.'));
    for (final secret in ['Ledger', '90817263', '1357']) {
      expect(blob, isNot(contains(secret)));
    }
    final loaded = await store.load();
    expect([
      for (final v in loaded) (v.id, v.name, v.vector)
    ], [
      ('a1', 'Ledger 1', '90817263'),
      ('b2', 'Ledger 2', '1357'),
    ]);
    expect(loaded.every((v) => !v.fromVault), isTrue);
  });

  test('the key is an HKDF subkey of the account key, not the key itself',
      () async {
    await store.save([_ledger1]);
    final cs = CipherString.parse((await _keychain())[_setKey]!);
    expect(() => crypto.decryptSymmetric(cs, userKey!), throwsStateError,
        reason: 'the vault key must not open app data directly');
    final subkey = hkdfExpandSha256(
        userKey!, utf8.encode(EncryptedShiftVectorStore.kdfInfo), 64);
    final json = jsonDecode(utf8.decode(crypto.decryptSymmetric(cs, subkey)));
    expect(json['v'], 1);
    expect(json['entries'], [
      {'id': 'a1', 'name': 'Ledger 1', 'vector': '90817263'},
    ]);
  });

  test('every save uses a fresh IV', () async {
    await store.save([_ledger1]);
    final first = (await _keychain())[_setKey];
    await store.save([_ledger1]);
    expect((await _keychain())[_setKey], isNot(first));
  });

  test('another account (or a rotated key): otherAccount, then discard',
      () async {
    await store.save([_ledger1]);
    final other = storeWith(() => _randomKey(2));
    await expectLater(
      other.load(),
      throwsA(isA<ShiftVectorException>().having(
          (e) => e.failure, 'failure', ShiftVectorFailure.otherAccount)),
    );
    // Still there for the right account …
    expect((await store.load()).single.name, 'Ledger 1');
    // … until the other one deletes it.
    await other.discard();
    expect(await _keychain(), isEmpty);
    expect(await store.load(), isEmpty);
  });

  test('a damaged item: corrupt', () async {
    for (final bad in ['garbage', '2.AAAA|AAAA', '0.aXY=|Y3Q=']) {
      FlutterSecureStorage.setMockInitialValues({_setKey: bad});
      await expectLater(
        store.load(),
        throwsA(isA<ShiftVectorException>()
            .having((e) => e.failure, 'failure', ShiftVectorFailure.corrupt)),
        reason: bad,
      );
    }
    // Valid encryption of something that is not the set.
    final subkey = hkdfExpandSha256(
        userKey!, utf8.encode(EncryptedShiftVectorStore.kdfInfo), 64);
    final notJson = crypto
        .encryptSymmetric(Uint8List.fromList(utf8.encode('[1,2]')), subkey)
        .encode();
    FlutterSecureStorage.setMockInitialValues({_setKey: notJson});
    await expectLater(
      store.load(),
      throwsA(isA<ShiftVectorException>()
          .having((e) => e.failure, 'failure', ShiftVectorFailure.corrupt)),
    );
  });

  test('invalid entries are dropped, valid ones kept', () async {
    final subkey = hkdfExpandSha256(
        userKey!, utf8.encode(EncryptedShiftVectorStore.kdfInfo), 64);
    final plain = utf8.encode(jsonEncode({
      'v': 1,
      'entries': [
        {'id': 'a1', 'name': 'Ledger 1', 'vector': '90817263'},
        {'id': 'x', 'name': 'Bad', 'vector': '12ab'},
        {'id': '', 'name': 'No id', 'vector': '1234'},
        {'id': 'y', 'name': '  ', 'vector': '1234'},
        {'id': 'z', 'name': 'Too long', 'vector': '12345678901234567'},
        'not a map',
      ],
    }));
    FlutterSecureStorage.setMockInitialValues({
      _setKey:
          crypto.encryptSymmetric(Uint8List.fromList(plain), subkey).encode(),
    });
    expect([for (final v in await store.load()) v.id], ['a1']);
  });

  test('locked (no key, or zeroed by lock()): locked, nothing written',
      () async {
    await store.save([_ledger1]);
    final before = await _keychain();
    for (final key in <Uint8List?>[null, Uint8List(64), Uint8List(32)]) {
      final locked = storeWith(() => key);
      await expectLater(
        locked.load(),
        throwsA(isA<ShiftVectorException>()
            .having((e) => e.failure, 'failure', ShiftVectorFailure.locked)),
      );
      await expectLater(
        locked.save([_ledger2]),
        throwsA(isA<ShiftVectorException>()
            .having((e) => e.failure, 'failure', ShiftVectorFailure.locked)),
      );
    }
    expect(await _keychain(), before);
    // lock() zeroes the live key in place: the store reads it every time.
    userKey!.fillRange(0, 64, 0);
    await expectLater(store.load(), throwsA(isA<ShiftVectorException>()));
  });

  test('the live key is not modified by the store', () async {
    final copy = Uint8List.fromList(userKey!);
    await store.save([_ledger1]);
    await store.load();
    expect(userKey, copy);
  });

  test('save([]) deletes the set', () async {
    await store.save([_ledger1]);
    await store.save([]);
    expect(await _keychain(), isEmpty);
  });

  group('migration from the 1.1.0 single vector (P2)', () {
    test('the plain vector becomes "PIN Shift" in the set, then is deleted',
        () async {
      FlutterSecureStorage.setMockInitialValues({_legacyKey: '90817263'});
      final first = await store.load();
      expect(first.single.name, 'PIN Shift');
      expect(first.single.vector, '90817263');
      final items = await _keychain();
      expect(items.keys, [_setKey]);
      expect(items[_setKey], isNot(contains('90817263')));
      // Stable from then on.
      final second = await store.load();
      expect(second.single.id, first.single.id);
    });

    test('appended to an existing set; same digits are not duplicated',
        () async {
      await store.save([
        const ShiftVector(id: 'p', name: 'PIN Shift', vector: '1111'),
      ]);
      await storage.saveShiftVector('2222');
      final merged = await store.load();
      expect([
        for (final v in merged) (v.name, v.vector)
      ], [
        ('PIN Shift', '1111'),
        ('PIN Shift 2', '2222'),
      ]);
      await storage.saveShiftVector('1111');
      expect(await store.load(), hasLength(2));
      expect((await _keychain()).containsKey(_legacyKey), isFalse);
    });

    test('not migrated while locked or for another account', () async {
      await store.save([_ledger1]);
      await storage.saveShiftVector('2222');
      await expectLater(
          storeWith(() => _randomKey(9)).load(), throwsA(anything));
      expect((await _keychain())[_legacyKey], '2222');
      await expectLater(storeWith(() => null).load(), throwsA(anything));
      expect((await _keychain())[_legacyKey], '2222');
    });

    test('an unusable plain value is dropped', () async {
      FlutterSecureStorage.setMockInitialValues({_legacyKey: '12ab'});
      expect(await store.load(), isEmpty);
      expect(await _keychain(), isEmpty);
    });
  });

  test('a keychain that cannot be read: unavailable, never "none"', () async {
    final keychain = FakeAppleKeychain()..metadataReadableWhileLocked = true;
    final ios = appleStorage(keychain);
    final iosStore = EncryptedShiftVectorStore(
        storage: ios, crypto: crypto, userKey: () => userKey);
    await iosStore.save([_ledger1]);
    keychain.locked = true;
    await expectLater(
      iosStore.load(),
      throwsA(isA<ShiftVectorException>()
          .having((e) => e.failure, 'failure', ShiftVectorFailure.unavailable)),
    );
    keychain.locked = false;
    expect((await iosStore.load()).single.name, 'Ledger 1');
  });
}
