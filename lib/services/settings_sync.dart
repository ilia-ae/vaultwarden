import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../models/settings_snapshot.dart';
import 'auth_service.dart';

// ── Firebase service providers ──

final firebaseAuthProvider =
    Provider<FirebaseAuth>((_) => FirebaseAuth.instance);

final firestoreProvider =
    Provider<FirebaseFirestore>((_) => FirebaseFirestore.instance);

final authServiceProvider = Provider<AuthService>(
    (ref) => AuthService(ref.watch(firebaseAuthProvider)));

/// Current signed-in user (null = signed out). Drives the account UI.
/// userChanges (not authStateChanges) so provider-linking is reflected live —
/// the coordinator below only reacts to uid changes, so extra emissions are
/// harmless there.
final authStateProvider = StreamProvider<User?>(
    (ref) => ref.watch(firebaseAuthProvider).userChanges());

// ── Firestore read/write of the settings document ──

class SettingsSyncService {
  SettingsSyncService(this._db);

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      _db.collection('users').doc(uid);

  /// Merge-writes [s] (see [documentFor]).
  Future<void> push(String uid, SettingsSnapshot s) =>
      _doc(uid).set(documentFor(s), SetOptions(merge: true));

  /// The fields [push] writes: the synced values plus a server timestamp.
  /// A local "never lock" is not synced, so `lockTimeout` is then absent
  /// and the merge keeps whatever other devices synced (A15/K6).
  @visibleForTesting
  static Map<String, dynamic> documentFor(SettingsSnapshot s) => {
        ...s.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
      };

  /// Deletes the user's settings document (account deletion, H2). The
  /// document has no sub-collections. Firestore only completes a delete once
  /// the server has it, so an offline device times out instead of hanging.
  Future<void> delete(String uid) =>
      _doc(uid).delete().timeout(const Duration(seconds: 20));

  Stream<SettingsSnapshot?> watch(String uid) =>
      _doc(uid).snapshots().map((snap) {
        final data = snap.data();
        return data == null ? null : SettingsSnapshot.fromMap(data);
      });
}

final settingsSyncServiceProvider = Provider<SettingsSyncService>(
    (ref) => SettingsSyncService(ref.watch(firestoreProvider)));

// ── Two-way sync coordinator ──

/// Keeps the local settings providers and the Firestore document in sync
/// while a user is signed in. Loop-safe: a locally-applied remote snapshot
/// is remembered as [_lastRemote] and never echoed back as a push.
///
/// "Never lock" (lockTimeout -1) is local-only (A15): it is never uploaded
/// (the field is omitted, so the document keeps the last synced value) and
/// never applied from the cloud; while it is set locally, remote lock
/// timeouts are ignored on this device.
class SettingsSyncCoordinator {
  SettingsSyncCoordinator(this._ref) {
    _ref.listen<AsyncValue<User?>>(
      authStateProvider,
      (_, next) => _onUser(next.valueOrNull),
      fireImmediately: true,
    );

    // Push local edits up (debounced) once signed in.
    _ref.listen<ThemeMode>(themeModeProvider, (_, __) => _onLocalChange());
    _ref.listen<Locale?>(localeProvider, (_, __) => _onLocalChange());
    _ref.listen<int>(lockTimeoutProvider, (_, __) => _onLocalChange());
    _ref.listen<int>(pollIntervalProvider, (_, __) => _onLocalChange());
  }

  final Ref _ref;
  StreamSubscription<SettingsSnapshot?>? _remoteSub;
  Timer? _pushDebounce;
  String? _uid;
  SettingsSnapshot? _lastRemote;

  /// True while [deleteAccount] runs: nothing is watched or pushed.
  bool _suspended = false;

  void _onUser(User? user) {
    if (user?.uid == _uid) return;
    _uid = user?.uid;
    _remoteSub?.cancel();
    _remoteSub = null;
    _lastRemote = null;
    if (_uid == null || _suspended) return;
    _subscribe(_uid!);
  }

  void _subscribe(String uid) {
    _remoteSub = _ref
        .read(settingsSyncServiceProvider)
        .watch(uid)
        .listen(_onRemote, onError: (_) {});
  }

  /// Deletes the signed-in cloud-sync account and its settings document
  /// (H1–H3). Sync is suspended meanwhile: the watch would report the
  /// deleted document as a first sign-in and seed it again from local state.
  /// If the deletion fails and the user is still signed in, sync resumes.
  /// Throws what [AuthService.deleteAccount] throws.
  Future<void> deleteAccount() async {
    _suspended = true;
    _pushDebounce?.cancel();
    _remoteSub?.cancel();
    _remoteSub = null;
    _lastRemote = null;
    try {
      await _ref.read(authServiceProvider).deleteAccount(
            deleteData: _ref.read(settingsSyncServiceProvider).delete,
          );
    } finally {
      _suspended = false;
      final uid = _uid;
      if (uid != null &&
          _remoteSub == null &&
          _ref.read(authServiceProvider).currentUser?.uid == uid) {
        _subscribe(uid);
      }
    }
  }

  void _onRemote(SettingsSnapshot? remote) {
    if (_suspended) return;
    if (remote == null) {
      // First sign-in with no cloud doc yet — seed it from local state.
      _pushNow(_currentSnapshot());
      return;
    }
    _lastRemote = remote;
    _applyRemote(remote);
  }

  void _applyRemote(SettingsSnapshot s) {
    _ref.read(themeModeProvider.notifier).state = _parseTheme(s.themeMode);
    _ref.read(localeProvider.notifier).state = _parseLocale(s.locale);
    // "Never lock" is per device (A15): a remote value never replaces it,
    // and a remote "never" is never applied (fromMap drops it).
    final lock = s.lockTimeout;
    if (lock != null && _ref.read(lockTimeoutProvider) != kLockTimeoutNever) {
      _ref.read(lockTimeoutProvider.notifier).state = lock;
    }
    _ref.read(pollIntervalProvider.notifier).state =
        sanitizePollInterval(s.pollInterval);
  }

  void _onLocalChange() {
    if (_uid == null || _suspended) return;
    final current = _currentSnapshot();
    final last = _lastRemote;
    // Nothing new vs the cloud (a local-only "never" is not a difference).
    if (last != null && current.sameSyncedValues(last)) return;
    _pushDebounce?.cancel();
    _pushDebounce =
        Timer(const Duration(milliseconds: 800), () => _pushNow(current));
  }

  void _pushNow(SettingsSnapshot s) {
    final uid = _uid;
    if (uid == null || _suspended) return;
    _lastRemote = s; // treat as the new baseline so it isn't echoed
    _ref.read(settingsSyncServiceProvider).push(uid, s).catchError((_) {});
  }

  /// The local settings as synced: a local "never lock" is not uploaded.
  SettingsSnapshot _currentSnapshot() => SettingsSnapshot(
        themeMode: _ref.read(themeModeProvider).name,
        locale: _ref.read(localeProvider)?.toLanguageTag(),
        lockTimeout: syncedLockTimeout(_ref.read(lockTimeoutProvider)),
        pollInterval: sanitizePollInterval(_ref.read(pollIntervalProvider)),
      );

  static ThemeMode _parseTheme(String s) => switch (s) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  static Locale? _parseLocale(String? tag) {
    if (tag == null || tag.isEmpty) return null;
    final parts = tag.split('-');
    if (parts.length == 1) return Locale(parts[0]);
    final second = parts[1];
    if (second.length == 4) {
      return Locale.fromSubtags(languageCode: parts[0], scriptCode: second);
    }
    return Locale(parts[0], second);
  }

  void dispose() {
    _remoteSub?.cancel();
    _pushDebounce?.cancel();
  }
}

/// Activated by watching it from the App widget (only when Firebase is ready).
final settingsSyncCoordinatorProvider =
    Provider<SettingsSyncCoordinator>((ref) {
  final coordinator = SettingsSyncCoordinator(ref);
  ref.onDispose(coordinator.dispose);
  return coordinator;
});
