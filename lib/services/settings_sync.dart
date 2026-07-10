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

final authServiceProvider =
    Provider<AuthService>((ref) => AuthService(ref.watch(firebaseAuthProvider)));

/// Current signed-in user (null = signed out). Drives the account UI.
final authStateProvider = StreamProvider<User?>(
    (ref) => ref.watch(firebaseAuthProvider).authStateChanges());

// ── Firestore read/write of the settings document ──

class SettingsSyncService {
  SettingsSyncService(this._db);

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      _db.collection('users').doc(uid);

  Future<void> push(String uid, SettingsSnapshot s) => _doc(uid).set({
        ...s.toMap(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

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

  void _onUser(User? user) {
    if (user?.uid == _uid) return;
    _uid = user?.uid;
    _remoteSub?.cancel();
    _remoteSub = null;
    _lastRemote = null;
    if (_uid == null) return;

    _remoteSub = _ref
        .read(settingsSyncServiceProvider)
        .watch(_uid!)
        .listen(_onRemote, onError: (_) {});
  }

  void _onRemote(SettingsSnapshot? remote) {
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
    _ref.read(lockTimeoutProvider.notifier).state = s.lockTimeout;
    _ref.read(pollIntervalProvider.notifier).state = s.pollInterval;
  }

  void _onLocalChange() {
    if (_uid == null) return;
    final current = _currentSnapshot();
    if (current == _lastRemote) return; // nothing new vs the cloud
    _pushDebounce?.cancel();
    _pushDebounce =
        Timer(const Duration(milliseconds: 800), () => _pushNow(current));
  }

  void _pushNow(SettingsSnapshot s) {
    final uid = _uid;
    if (uid == null) return;
    _lastRemote = s; // treat as the new baseline so it isn't echoed
    _ref.read(settingsSyncServiceProvider).push(uid, s).catchError((_) {});
  }

  SettingsSnapshot _currentSnapshot() => SettingsSnapshot(
        themeMode: _ref.read(themeModeProvider).name,
        locale: _ref.read(localeProvider)?.toLanguageTag(),
        lockTimeout: _ref.read(lockTimeoutProvider),
        pollInterval: _ref.read(pollIntervalProvider),
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
