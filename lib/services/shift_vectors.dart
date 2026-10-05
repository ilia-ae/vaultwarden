import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Named PIN Shift vectors: what PIN Shift may save and read.
///
/// The PIN code reaches saved vectors only through these narrow interfaces
/// (it may not import the storage, crypto or network services, see
/// `no_network_imports_test.dart`); `main()` wires the real implementations.
///
/// The concept (personal-crypto-tools `security-concept/
/// pin-ledger-pin-shift.md`): every Ledger has its own memorised PIN and its
/// own random vector, kept in three places — Bitwarden, a separate store and
/// this app. A vector is therefore always named after what it belongs to, and
/// the result always says which vector made it.

/// A saved shift vector. [vector] is ASCII digits (1–16); [name] is the
/// user's label ("Ledger 1"). Both are secret enough to stay encrypted at
/// rest; only [id] (random) may be kept in plain preferences.
class ShiftVector {
  const ShiftVector({
    required this.id,
    required this.name,
    required this.vector,
    this.fromVault = false,
  });

  final String id;
  final String name;
  final String vector;

  /// Read from a Bitwarden vault item (experimental), not saved in the app.
  final bool fromVault;

  int get length => vector.length;

  ShiftVector copyWith({String? name, String? vector}) => ShiftVector(
        id: id,
        name: name ?? this.name,
        vector: vector ?? this.vector,
        fromVault: fromVault,
      );

  Map<String, Object> toJson() => {'id': id, 'name': name, 'vector': vector};

  /// Null when [json] is not a valid saved entry.
  static ShiftVector? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    final vector = json['vector'];
    if (id is! String || id.isEmpty) return null;
    if (name is! String || name.trim().isEmpty) return null;
    if (vector is! String || !isShiftVectorDigits(vector)) return null;
    return ShiftVector(id: id, name: name, vector: vector);
  }

  // Never print a vector.
  @override
  String toString() => 'ShiftVector($id, ${vector.length} digits)';
}

/// 1–16 ASCII digits: what a saved vector may be.
bool isShiftVectorDigits(String s) =>
    s.isNotEmpty && s.length <= 16 && RegExp(r'^[0-9]+$').hasMatch(s);

/// Limits for the saved set.
const int kMaxShiftVectors = 30;
const int kMaxShiftVectorNameLength = 40;

/// A random id for a new saved vector (16 hex digits). Ids are not secret:
/// the last chosen one is remembered in plain preferences.
String newShiftVectorId() {
  final r = Random.secure();
  return [
    for (var i = 0; i < 8; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')
  ].join();
}

/// [name] as saved: trimmed, inner whitespace collapsed to one space.
String normalizeShiftVectorName(String name) =>
    name.trim().replaceAll(RegExp(r'\s+'), ' ');

/// Whether [a] and [b] name the same vector (case-insensitive, normalized).
bool sameShiftVectorName(String a, String b) =>
    normalizeShiftVectorName(a).toLowerCase() ==
    normalizeShiftVectorName(b).toLowerCase();

/// [base], or "[base] 2", "[base] 3"… — the first not taken in [taken].
String uniqueShiftVectorName(String base, Iterable<ShiftVector> taken) {
  bool used(String n) => taken.any((v) => sameShiftVectorName(v.name, n));
  if (!used(base)) return base;
  for (var i = 2;; i++) {
    final candidate = '$base $i';
    if (!used(candidate)) return candidate;
  }
}

/// Why the saved vectors could not be read or written.
enum ShiftVectorFailure {
  /// The vault is locked: no account key in memory.
  locked,

  /// The set was encrypted with another account's key (another account
  /// signed in, or the account key was rotated). It cannot be opened; it
  /// can only be deleted.
  otherAccount,

  /// The stored set is damaged. It can only be deleted.
  corrupt,

  /// The device keychain could not be read or written right now.
  unavailable,
}

class ShiftVectorException implements Exception {
  const ShiftVectorException(this.failure);

  final ShiftVectorFailure failure;

  @override
  String toString() => 'ShiftVectorException(${failure.name})';
}

/// The vectors saved in the app, encrypted with the Bitwarden account key.
abstract interface class ShiftVectorStore {
  /// The saved vectors in their saved order (empty when none). Throws
  /// [ShiftVectorException]; an unreadable set is never reported as empty.
  Future<List<ShiftVector>> load();

  /// Replaces the saved set with [vectors] (empty deletes it). Throws
  /// [ShiftVectorException].
  Future<void> save(List<ShiftVector> vectors);

  /// Deletes the saved set without opening it (for [otherAccount] /
  /// [corrupt] sets).
  Future<void> discard();
}

/// Reads vectors from the user's Bitwarden vault (experimental, off by
/// default): items with a custom field named "PIN Shift".
abstract interface class ShiftVectorSource {
  /// Throws [ShiftVectorException] (locked) or the network error as is.
  Future<List<ShiftVector>> fetch();
}

/// The store PIN Shift saves vectors in; `null` (nothing wired, e.g. a
/// widget test of another screen) means PIN Shift offers no saving.
final shiftVectorStoreProvider = Provider<ShiftVectorStore?>((_) => null);

/// The Bitwarden vault reader; `null` hides the experimental option.
final shiftVectorSourceProvider = Provider<ShiftVectorSource?>((_) => null);

/// Demo builds and the runtime demo: saved vectors live in memory only and
/// never touch the device keychain.
class InMemoryShiftVectorStore implements ShiftVectorStore {
  List<ShiftVector> _vectors = const [];

  @override
  Future<List<ShiftVector>> load() async => List.of(_vectors);

  @override
  Future<void> save(List<ShiftVector> vectors) async =>
      _vectors = List.unmodifiable(vectors);

  @override
  Future<void> discard() async => _vectors = const [];
}
