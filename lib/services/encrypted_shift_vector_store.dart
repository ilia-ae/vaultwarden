import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models/cipher_string.dart';
import 'crypto_service.dart';
import 'secure_storage_service.dart';
import 'shift_vectors.dart';

/// PIN Shift's saved vectors in the device keychain, encrypted with the
/// Bitwarden account key.
///
/// One keychain item ([SecureStorageService.keyPinShiftVectors]) holds an
/// EncString type 2 (AES-256-CBC + HMAC-SHA256, as Bitwarden) of
/// `{"v":1,"entries":[{id,name,vector}…]}`. The key is a subkey of the user
/// key — HKDF-Expand(userKey, [kdfInfo], 64) — so the set opens only while
/// the vault is unlocked, and only for the account that saved it: after a
/// sign-out it stays on the device and opens again when the same account
/// signs in; another account (or a rotated account key) fails the MAC and
/// the set can only be deleted.
///
/// The single plain vector of 1.1.0 ([SecureStorageService.keyPinShiftVector])
/// is moved into the set on the first load and deleted after the set is
/// written.
class EncryptedShiftVectorStore implements ShiftVectorStore {
  EncryptedShiftVectorStore({
    required SecureStorageService storage,
    required CryptoService crypto,
    required Uint8List? Function() userKey,
  })  : _storage = storage,
        _crypto = crypto,
        _userKey = userKey;

  final SecureStorageService _storage;
  final CryptoService _crypto;

  /// The live user key (`userKeyProvider`); `lock()` zeroes it in place, so
  /// it is copied before use.
  final Uint8List? Function() _userKey;

  @visibleForTesting
  static const kdfInfo = 'vaultapprover/pin-shift-vectors/v1';

  /// Name of the vector migrated from 1.1.0 (the user can rename it).
  @visibleForTesting
  static const legacyName = 'PIN Shift';

  @override
  Future<List<ShiftVector>> load() async {
    final String? blob;
    final String? legacy;
    try {
      blob = await _storage.loadShiftVectors();
      legacy = await _storage.loadShiftVector();
    } catch (_) {
      throw const ShiftVectorException(ShiftVectorFailure.unavailable);
    }
    if (blob == null && legacy == null) return [];

    final key = _subkey();
    try {
      var vectors = blob == null ? <ShiftVector>[] : _decrypt(blob, key);
      if (legacy != null) {
        final digits = legacy.trim();
        if (isShiftVectorDigits(digits) &&
            !vectors.any((v) => v.vector == digits)) {
          vectors = [
            ...vectors,
            ShiftVector(
              id: newShiftVectorId(),
              name: uniqueShiftVectorName(legacyName, vectors),
              vector: digits,
            ),
          ];
          await _write(vectors, key);
        }
        try {
          await _storage.deleteShiftVector();
        } catch (_) {
          // Retried on the next load; the set already holds the vector.
        }
      }
      return vectors;
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  @override
  Future<void> save(List<ShiftVector> vectors) async {
    if (vectors.isEmpty) return discard();
    final key = _subkey();
    try {
      await _write(vectors, key);
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  @override
  Future<void> discard() async {
    try {
      await _storage.deleteShiftVectors();
    } catch (_) {
      throw const ShiftVectorException(ShiftVectorFailure.unavailable);
    }
  }

  // ── Helpers ──

  /// The set's 64-byte key, derived from a copy of the user key.
  Uint8List _subkey() {
    final live = _userKey();
    if (live == null || live.length != 64 || live.every((b) => b == 0)) {
      throw const ShiftVectorException(ShiftVectorFailure.locked);
    }
    final userKey = Uint8List.fromList(live);
    try {
      return hkdfExpandSha256(userKey, utf8.encode(kdfInfo), 64);
    } finally {
      userKey.fillRange(0, userKey.length, 0);
    }
  }

  List<ShiftVector> _decrypt(String blob, Uint8List key) {
    final Uint8List plain;
    try {
      plain = _crypto.decryptSymmetric(CipherString.parse(blob), key);
    } on StateError {
      // MAC mismatch: another account's (or a rotated) key.
      throw const ShiftVectorException(ShiftVectorFailure.otherAccount);
    } catch (_) {
      throw const ShiftVectorException(ShiftVectorFailure.corrupt);
    }
    try {
      final json = jsonDecode(utf8.decode(plain));
      final entries = json is Map ? json['entries'] : null;
      if (entries is! List) {
        throw const ShiftVectorException(ShiftVectorFailure.corrupt);
      }
      return [
        for (final e in entries)
          if (ShiftVector.fromJson(e) case final v?) v,
      ];
    } on ShiftVectorException {
      rethrow;
    } catch (_) {
      throw const ShiftVectorException(ShiftVectorFailure.corrupt);
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
  }

  Future<void> _write(List<ShiftVector> vectors, Uint8List key) async {
    final plain = Uint8List.fromList(utf8.encode(jsonEncode({
      'v': 1,
      'entries': [for (final v in vectors) v.toJson()],
    })));
    final String encoded;
    try {
      encoded = _crypto.encryptSymmetric(plain, key).encode();
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
    try {
      await _storage.saveShiftVectors(encoded);
    } catch (_) {
      // The write is owed (applied once the keychain can take it) or failed.
      throw const ShiftVectorException(ShiftVectorFailure.unavailable);
    }
  }
}
