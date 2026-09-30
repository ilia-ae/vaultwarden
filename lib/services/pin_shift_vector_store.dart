import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where PIN Shift keeps the vector the user chose to remember on this
/// device: the device keychain / keystore (`SecureStorageService` implements
/// it, key `pin_shift_vector`).
///
/// A narrow interface on purpose: the PIN code reaches the keychain only
/// through these three calls (it may not import the storage service, which
/// also holds the session and keys, see `no_network_imports_test.dart`).
///
/// Device data, not vault account data: signing out keeps the vector, a full
/// reset or a reinstall removes it. Never in SharedPreferences, the settings
/// snapshot or the cloud; never printed.
abstract interface class PinShiftVectorStore {
  /// The saved vector (ASCII digits), or `null` when none is saved. Throws
  /// (`SecureStorageReadException`) when the keychain cannot be read, which
  /// is never reported as "none saved".
  Future<String?> loadShiftVector();

  /// Saves [vector] (ASCII digits), replacing a saved one.
  Future<void> saveShiftVector(String vector);

  /// Removes the saved vector (nothing happens when none is saved).
  Future<void> deleteShiftVector();
}

/// The store PIN Shift saves its vector in. `main()` wires it to the app's
/// `SecureStorageService`; `null` (no keychain wired, e.g. a widget test of
/// another screen) means PIN Shift offers no saving at all.
final pinShiftVectorStoreProvider = Provider<PinShiftVectorStore?>((_) => null);
