import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart' show FieldValue;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_approver/app.dart';
import 'package:vault_approver/models/settings_snapshot.dart';
import 'package:vault_approver/services/auth_service.dart';
import 'package:vault_approver/services/settings_service.dart';
import 'package:vault_approver/services/settings_sync.dart';

class _FakeUser extends Fake implements User {
  @override
  String get uid => 'uid-1';
}

class _FakeSync extends Fake implements SettingsSyncService {
  final remote = StreamController<SettingsSnapshot?>.broadcast();
  final pushes = <Map<String, dynamic>>[];
  final deleted = <String>[];
  int watches = 0;

  @override
  Future<void> push(String uid, SettingsSnapshot s) async =>
      pushes.add(s.toMap());

  @override
  Future<void> delete(String uid) async => deleted.add(uid);

  @override
  Stream<SettingsSnapshot?> watch(String uid) {
    watches++;
    return remote.stream;
  }

  /// What Firestore would deliver for [doc] (parsed like the real service).
  void deliver(Map<String, dynamic>? doc) =>
      remote.add(doc == null ? null : SettingsSnapshot.fromMap(doc));
}

/// Stands in for Apple/Google + Firebase: [deleteAccount] runs the real
/// data callback, then [onDelete] (e.g. a late remote snapshot or a failure).
class _FakeAuthService extends Fake implements AuthService {
  _FakeAuthService(this.user);

  User? user;
  Future<void> Function()? onDelete;

  @override
  User? get currentUser => user;

  @override
  Future<void> deleteAccount({
    required Future<void> Function(String uid) deleteData,
  }) async {
    await deleteData(user!.uid);
    await onDelete?.call();
  }
}

Future<(ProviderContainer, _FakeSync)> _signedInSync(
  WidgetTester tester, {
  Map<String, Object> prefs = const {},
  AuthService? auth,
  Stream<User?>? users,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final settings = SettingsService(await SharedPreferences.getInstance());
  final sync = _FakeSync();
  final container = ProviderContainer(overrides: [
    settingsServiceProvider.overrideWithValue(settings),
    settingsSyncServiceProvider.overrideWithValue(sync),
    authStateProvider.overrideWith((ref) => users ?? Stream.value(_FakeUser())),
    if (auth != null) authServiceProvider.overrideWithValue(auth),
  ]);
  container.read(settingsSyncCoordinatorProvider);
  await tester.pump(); // signed-in user arrives, remote doc subscribed
  return (container, sync);
}

void main() {
  group('SettingsSnapshot.fromMap validation (R2, A15)', () {
    test('poll interval is clamped to at least 5 s', () {
      for (final bad in [0, -3, 1, 4.9]) {
        expect(SettingsSnapshot.fromMap({'pollInterval': bad}).pollInterval,
            kMinPollIntervalSeconds,
            reason: '$bad');
      }
      expect(SettingsSnapshot.fromMap({'pollInterval': 'x'}).pollInterval,
          kDefaultPollIntervalSeconds);
      expect(SettingsSnapshot.fromMap({}).pollInterval,
          kDefaultPollIntervalSeconds);
      expect(SettingsSnapshot.fromMap({'pollInterval': 1e9}).pollInterval,
          kMaxPollIntervalSeconds);
      expect(SettingsSnapshot.fromMap({'pollInterval': 30}).pollInterval, 30);
    });

    test('lock timeout: whitelist only, "never" is not synced', () {
      for (final v in [0, 15, 60, 300, 900]) {
        expect(SettingsSnapshot.fromMap({'lockTimeout': v}).lockTimeout, v);
      }
      for (final v in [-1, 42, -5, 1.5, 'never', null]) {
        expect(SettingsSnapshot.fromMap({'lockTimeout': v}).lockTimeout, isNull,
            reason: '$v');
      }
    });

    test('unknown theme falls back to system; bad locale is dropped', () {
      final s = SettingsSnapshot.fromMap({'themeMode': 'neon', 'locale': 7});
      expect(s.themeMode, 'system');
      expect(s.locale, isNull);
    });

    test('toMap omits a lock timeout that is not synced', () {
      const s = SettingsSnapshot(
        themeMode: 'dark',
        locale: null,
        lockTimeout: null,
        pollInterval: 15,
      );
      expect(s.toMap().containsKey('lockTimeout'), isFalse);
      expect(
          s.sameSyncedValues(const SettingsSnapshot(
            themeMode: 'dark',
            locale: null,
            lockTimeout: 60,
            pollInterval: 15,
          )),
          isTrue);
    });

    test('local sanitisers', () {
      expect(sanitizeLockTimeout(-1), -1);
      expect(sanitizeLockTimeout(42), 0);
      expect(sanitizeLockTimeout(null), 0);
      expect(syncedLockTimeout(-1), isNull);
      expect(syncedLockTimeout(900), 900);
    });
  });

  group('local settings providers', () {
    test('corrupt prefs are sanitised', () async {
      SharedPreferences.setMockInitialValues({
        'settings.poll_interval': 0,
        'settings.lock_timeout': 42,
      });
      final settings = SettingsService(await SharedPreferences.getInstance());
      final c = ProviderContainer(overrides: [
        settingsServiceProvider.overrideWithValue(settings),
      ]);
      expect(c.read(pollIntervalProvider), kMinPollIntervalSeconds);
      expect(c.read(lockTimeoutProvider), 0);
      c.dispose();
    });
  });

  group('SettingsSyncCoordinator (A15)', () {
    testWidgets('remote "never", unknown lock values and poll 0 are sanitised',
        (tester) async {
      final (c, sync) = await _signedInSync(tester, prefs: {
        'settings.lock_timeout': 60,
        'settings.poll_interval': 15,
      });
      sync.deliver({'themeMode': 'dark', 'lockTimeout': -1, 'pollInterval': 0});
      await tester.pump();
      expect(c.read(themeModeProvider), ThemeMode.dark);
      expect(c.read(lockTimeoutProvider), 60);
      expect(c.read(pollIntervalProvider), 5);

      sync.deliver({'lockTimeout': 42});
      await tester.pump();
      expect(c.read(lockTimeoutProvider), 60);
      c.dispose();
    });

    testWidgets('a synced lock timeout is applied and uploaded',
        (tester) async {
      final (c, sync) = await _signedInSync(tester, prefs: {
        'settings.lock_timeout': 0,
      });
      sync.deliver(
          {'themeMode': 'system', 'lockTimeout': 300, 'pollInterval': 15});
      await tester.pump();
      expect(c.read(lockTimeoutProvider), 300);

      c.read(lockTimeoutProvider.notifier).state = 60;
      await tester.pump(const Duration(seconds: 1));
      expect(sync.pushes.last['lockTimeout'], 60);
      c.dispose();
    });

    testWidgets('a local "never" is kept and never uploaded', (tester) async {
      final (c, sync) = await _signedInSync(tester, prefs: {
        'settings.lock_timeout': -1,
      });
      sync.deliver(
          {'themeMode': 'system', 'lockTimeout': 300, 'pollInterval': 15});
      await tester.pump();
      expect(c.read(lockTimeoutProvider), -1, reason: 'remote never overrides');

      c.read(themeModeProvider.notifier).state = ThemeMode.light;
      await tester.pump(const Duration(seconds: 1));
      expect(sync.pushes, isNotEmpty);
      expect(sync.pushes.last['themeMode'], 'light');
      expect(sync.pushes.last.containsKey('lockTimeout'), isFalse);

      // Choosing "never" locally is not a change worth uploading.
      final pushes = sync.pushes.length;
      c.read(lockTimeoutProvider.notifier).state = 300;
      sync.deliver({'themeMode': 'light', 'lockTimeout': 300});
      await tester.pump(const Duration(seconds: 1));
      c.read(lockTimeoutProvider.notifier).state = -1;
      await tester.pump(const Duration(seconds: 1));
      expect(sync.pushes.skip(pushes).where((p) => p['lockTimeout'] == -1),
          isEmpty);
      c.dispose();
    });

    // K6: the value the real service writes, not just the snapshot map.
    test('the pushed document never carries "never" (K6)', () {
      SettingsSnapshot local(int lockTimeout) => SettingsSnapshot(
            themeMode: 'dark',
            locale: 'ru',
            lockTimeout: syncedLockTimeout(lockTimeout),
            pollInterval: 30,
          );
      final never = SettingsSyncService.documentFor(local(kLockTimeoutNever));
      expect(never.containsKey('lockTimeout'), isFalse);
      expect(never['updatedAt'], isA<FieldValue>());
      expect(never.values, isNot(contains(kLockTimeoutNever)));
      expect(never.keys.toSet(),
          {'themeMode', 'locale', 'pollInterval', 'updatedAt'});

      final synced = SettingsSyncService.documentFor(local(300));
      expect(synced['lockTimeout'], 300);
    });

    testWidgets('a document without lockTimeout leaves the local value (K6)',
        (tester) async {
      // What a device on "never" leaves behind when it seeds the document.
      final (c, sync) = await _signedInSync(tester, prefs: {
        'settings.lock_timeout': 60,
      });
      sync.deliver({'themeMode': 'light', 'pollInterval': 30});
      await tester.pump();
      expect(c.read(themeModeProvider), ThemeMode.light);
      expect(c.read(lockTimeoutProvider), 60);
      await tester.pump(const Duration(seconds: 1));
      expect(sync.pushes.where((p) => p['lockTimeout'] == kLockTimeoutNever),
          isEmpty);
      c.dispose();
    });

    testWidgets('first sign-in seeds the document without "never"',
        (tester) async {
      final (c, sync) = await _signedInSync(tester, prefs: {
        'settings.lock_timeout': -1,
        'settings.poll_interval': 30,
      });
      sync.deliver(null);
      await tester.pump();
      expect(sync.pushes, hasLength(1));
      expect(sync.pushes.single.containsKey('lockTimeout'), isFalse);
      expect(sync.pushes.single['pollInterval'], 30);
      c.dispose();
    });
  });
  group('SettingsSyncCoordinator.deleteAccount (H3)', () {
    testWidgets('the deleted document is not seeded again', (tester) async {
      final users = StreamController<User?>.broadcast();
      final auth = _FakeAuthService(_FakeUser());
      final (c, sync) =
          await _signedInSync(tester, auth: auth, users: users.stream);
      users.add(_FakeUser());
      await tester.pump();
      sync.deliver({'themeMode': 'dark', 'pollInterval': 30});
      await tester.pump();
      final watches = sync.watches;

      auth.onDelete = () async {
        // Firestore reports the now-missing document; a local edit lands
        // meanwhile. Neither may write the document back.
        sync.deliver(null);
        c.read(themeModeProvider.notifier).state = ThemeMode.light;
        auth.user = null;
      };
      await c.read(settingsSyncCoordinatorProvider).deleteAccount();
      users.add(null);
      await tester.pump(const Duration(seconds: 2));

      expect(sync.deleted, ['uid-1']);
      expect(sync.pushes, isEmpty);
      expect(sync.watches, watches, reason: 'no new watch after deletion');
      c.dispose();
      await users.close();
    });

    testWidgets('a failed deletion resumes sync', (tester) async {
      final users = StreamController<User?>.broadcast();
      final auth = _FakeAuthService(_FakeUser());
      final (c, sync) =
          await _signedInSync(tester, auth: auth, users: users.stream);
      users.add(_FakeUser());
      await tester.pump();
      final watches = sync.watches;

      auth.onDelete = () async =>
          throw AuthException(AuthFailure.deleteFailed, detail: 'unavailable');
      await expectLater(
        c.read(settingsSyncCoordinatorProvider).deleteAccount(),
        throwsA(isA<AuthException>()),
      );
      expect(sync.watches, watches + 1, reason: 'watching again');

      sync.deliver({'themeMode': 'dark', 'pollInterval': 30});
      await tester.pump();
      expect(c.read(themeModeProvider), ThemeMode.dark);
      c.read(themeModeProvider.notifier).state = ThemeMode.light;
      await tester.pump(const Duration(seconds: 1));
      expect(sync.pushes.last['themeMode'], 'light');
      c.dispose();
      await users.close();
    });
  });
}
