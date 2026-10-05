import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/cipher_string.dart';
import '../models/json_util.dart';
import 'crypto_service.dart';
import 'shift_vectors.dart';
import 'vault_api.dart';

/// Experimental (off by default): PIN Shift vectors read from the user's
/// Bitwarden vault.
///
/// A vault item carries a vector in a custom field named "PIN Shift" (case,
/// spaces, "_" and "-" don't matter; a hidden field is best); the item's
/// name becomes the vector's name. Only personal items that are not in the
/// trash are read. Everything is decrypted on the device with the account
/// key; the vectors are returned to PIN Shift, which keeps them in memory
/// only — nothing from the vault is written to the device.
class VaultShiftVectorSource implements ShiftVectorSource {
  VaultShiftVectorSource({
    required VaultApiService api,
    required CryptoService crypto,
    required Uint8List? Function() userKey,
  })  : _api = api,
        _crypto = crypto,
        _userKey = userKey;

  final VaultApiService _api;
  final CryptoService _crypto;
  final Uint8List? Function() _userKey;

  @override
  Future<List<ShiftVector>> fetch() async {
    final ciphers = await _api.getCiphers();
    final live = _userKey();
    if (live == null || live.length != 64 || live.every((b) => b == 0)) {
      throw const ShiftVectorException(ShiftVectorFailure.locked);
    }
    final userKey = Uint8List.fromList(live);
    try {
      return shiftVectorsFromCiphers(ciphers, userKey, _crypto);
    } finally {
      userKey.fillRange(0, userKey.length, 0);
    }
  }
}

/// The normalized custom-field name that marks a vector.
const _fieldName = 'pinshift';

String _normalizeFieldName(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[\s_\-]'), '');

/// The vectors in [ciphers] (GET /api/ciphers items, camelCase or
/// PascalCase), sorted by name. Items that are not personal, are in the
/// trash, have no "PIN Shift" field, or fail to decrypt are skipped.
@visibleForTesting
List<ShiftVector> shiftVectorsFromCiphers(
  List<Object?> ciphers,
  Uint8List userKey,
  CryptoService crypto,
) {
  final out = <ShiftVector>[];
  for (final cipher in ciphers) {
    Uint8List? itemKey;
    try {
      if (cipher is! Map) continue;
      if (jsonGet(cipher, 'organizationId') != null) continue;
      if (jsonGet(cipher, 'deletedDate') != null) continue;
      final fields = jsonGet(cipher, 'fields');
      if (fields is! List || fields.isEmpty) continue;
      final id = jsonNonEmptyString(cipher, 'id');
      if (id == null) continue;

      // Items with their own key (newer clients): fields are encrypted with
      // it, the key itself with the user key.
      final keyEnc = jsonNonEmptyString(cipher, 'key');
      itemKey = keyEnc == null
          ? Uint8List.fromList(userKey)
          : crypto.decryptSymmetric(CipherString.parse(keyEnc), userKey);
      if (itemKey.length != 64) continue;

      String decrypt(String enc) {
        final bytes =
            crypto.decryptSymmetric(CipherString.parse(enc), itemKey!);
        try {
          return utf8.decode(bytes);
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      }

      String? vector;
      for (final field in fields) {
        final nameEnc = jsonNonEmptyString(field, 'name');
        final valueEnc = jsonNonEmptyString(field, 'value');
        if (nameEnc == null || valueEnc == null) continue;
        if (_normalizeFieldName(decrypt(nameEnc)) != _fieldName) continue;
        final digits = decrypt(valueEnc).replaceAll(RegExp(r'[\s\-]'), '');
        if (isShiftVectorDigits(digits)) {
          vector = digits;
          break;
        }
      }
      if (vector == null) continue;

      final nameEnc = jsonNonEmptyString(cipher, 'name');
      final name =
          nameEnc == null ? '' : normalizeShiftVectorName(decrypt(nameEnc));
      out.add(ShiftVector(
        id: 'vault:$id',
        name: name.isEmpty ? 'PIN Shift' : name,
        vector: vector,
        fromVault: true,
      ));
    } catch (_) {
      // One item we cannot read must not hide the others.
    } finally {
      itemKey?.fillRange(0, itemKey.length, 0);
    }
  }
  out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return out;
}
