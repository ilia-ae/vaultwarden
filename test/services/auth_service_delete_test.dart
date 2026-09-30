import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/services/auth_service.dart';

/// Account deletion (App Store 5.1.1(v), H1): the order of the steps and
/// that nothing is deleted when the confirming sign-in does not succeed.

class _Info extends Fake implements UserInfo {
  _Info(this.providerId);

  @override
  final String providerId;
}

class _Credential extends Fake implements UserCredential {
  _Credential(this.code);

  final String? code;

  @override
  AdditionalUserInfo? get additionalUserInfo =>
      AdditionalUserInfo(isNewUser: false, authorizationCode: code);
}

class _User extends Fake implements User {
  _User(this.log, List<String> providers, {this.appleCode = 'apple-code'})
      : providerData = [for (final p in providers) _Info(p)];

  final List<String> log;
  final String? appleCode;
  FirebaseAuthException? reauthError;
  FirebaseAuthException? deleteError;

  @override
  String get uid => 'uid-1';

  @override
  final List<UserInfo> providerData;

  @override
  Future<UserCredential> reauthenticateWithProvider(
      AuthProvider provider) async {
    log.add('reauth:${provider.providerId}');
    if (reauthError != null) throw reauthError!;
    return _Credential(appleCode);
  }

  @override
  Future<UserCredential> reauthenticateWithCredential(
      AuthCredential credential) async {
    log.add('reauth:${credential.providerId}');
    if (reauthError != null) throw reauthError!;
    return _Credential(null);
  }

  @override
  Future<void> delete() async {
    log.add('delete-user');
    if (deleteError != null) throw deleteError!;
  }
}

class _Auth extends Fake implements FirebaseAuth {
  _Auth(this.log, this.currentUser);

  final List<String> log;
  bool revokeFails = false;

  @override
  User? currentUser;

  @override
  Future<void> revokeTokenWithAuthorizationCode(String code) async {
    log.add('revoke:$code');
    if (revokeFails) throw FirebaseAuthException(code: 'invalid-credential');
  }

  @override
  Future<void> signOut() async {
    log.add('sign-out');
    currentUser = null;
  }
}

/// Google's native sheet and SDK are replaced; the rest is the real service.
class _Service extends AuthService {
  _Service(this.log, FirebaseAuth auth) : super(auth);

  final List<String> log;
  Object? googleError;

  @override
  Future<AuthCredential> googleCredential() async {
    log.add('google-sheet');
    if (googleError != null) throw googleError!;
    return GoogleAuthProvider.credential(idToken: 'id-token');
  }

  @override
  Future<void> disconnectGoogle() async => log.add('google-disconnect');
}

({List<String> log, _User user, _Auth auth, _Service service}) _setUp(
  List<String> providers, {
  String? appleCode = 'apple-code',
}) {
  final log = <String>[];
  final user = _User(log, providers, appleCode: appleCode);
  final auth = _Auth(log, user);
  return (log: log, user: user, auth: auth, service: _Service(log, auth));
}

Future<void> _deleteData(List<String> log, String uid) async =>
    log.add('data:$uid');

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Apple on iOS: re-auth, data, revoke, then the user', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final t = _setUp(['apple.com']);
    await t.service.deleteAccount(deleteData: (uid) => _deleteData(t.log, uid));
    expect(t.log, [
      'reauth:apple.com',
      'data:uid-1',
      'revoke:apple-code',
      'delete-user',
    ]);
  });

  test('Apple + Google on iOS: Apple confirms, Google grant dropped too',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final t = _setUp(['google.com', 'apple.com']);
    await t.service.deleteAccount(deleteData: (uid) => _deleteData(t.log, uid));
    expect(t.log, [
      'reauth:apple.com',
      'data:uid-1',
      'revoke:apple-code',
      'delete-user',
      'google-disconnect',
    ]);
  });

  test('Google (Android, Apple also linked): Google confirms, no revoke',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final t = _setUp(['google.com', 'apple.com']);
    await t.service.deleteAccount(deleteData: (uid) => _deleteData(t.log, uid));
    expect(t.log, [
      'google-sheet',
      'reauth:google.com',
      'data:uid-1',
      'delete-user',
      'google-disconnect',
    ]);
  });

  test('no signed-in user: nothing happens', () async {
    final t = _setUp(['apple.com']);
    t.auth.currentUser = null;
    await t.service.deleteAccount(deleteData: (uid) => _deleteData(t.log, uid));
    expect(t.log, isEmpty);
  });

  group('nothing is deleted when the confirmation fails', () {
    for (final code in ['canceled', 'user-cancelled', 'web-context-canceled']) {
      test('Apple sheet closed ($code) → cancelled', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        final t = _setUp(['apple.com']);
        t.user.reauthError = FirebaseAuthException(code: code);
        await expectLater(
          t.service.deleteAccount(deleteData: (uid) => _deleteData(t.log, uid)),
          throwsA(isA<AuthException>()
              .having((e) => e.failure, 'failure', AuthFailure.cancelled)),
        );
        expect(t.log, ['reauth:apple.com']);
      });
    }

    test('Google sheet closed → cancelled', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final t = _setUp(['google.com']);
      t.service.googleError =
          AuthException(AuthFailure.cancelled, provider: 'Google');
      await expectLater(
        t.service.deleteAccount(deleteData: (uid) => _deleteData(t.log, uid)),
        throwsA(isA<AuthException>()
            .having((e) => e.failure, 'failure', AuthFailure.cancelled)),
      );
      expect(t.log, ['google-sheet']);
    });

    test('another account picked → wrongAccount', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final t = _setUp(['google.com']);
      t.user.reauthError = FirebaseAuthException(code: 'user-mismatch');
      await expectLater(
        t.service.deleteAccount(deleteData: (uid) => _deleteData(t.log, uid)),
        throwsA(isA<AuthException>()
            .having((e) => e.failure, 'failure', AuthFailure.wrongAccount)
            .having((e) => e.provider, 'provider', 'Google')),
      );
      expect(t.log, ['google-sheet', 'reauth:google.com']);
    });

    test('other re-auth error → failed with the code', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final t = _setUp(['apple.com']);
      t.user.reauthError =
          FirebaseAuthException(code: 'network-request-failed');
      await expectLater(
        t.service.deleteAccount(deleteData: (uid) => _deleteData(t.log, uid)),
        throwsA(isA<AuthException>()
            .having((e) => e.failure, 'failure', AuthFailure.failed)
            .having((e) => e.detail, 'detail', 'network-request-failed')),
      );
      expect(t.log, ['reauth:apple.com']);
    });
  });

  test('a failed Apple revoke does not stop the deletion', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final t = _setUp(['apple.com']);
    t.auth.revokeFails = true;
    await t.service.deleteAccount(deleteData: (uid) => _deleteData(t.log, uid));
    expect(t.log, contains('delete-user'));
  });

  test('no authorization code from Apple: no revoke call', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final t = _setUp(['apple.com'], appleCode: null);
    await t.service.deleteAccount(deleteData: (uid) => _deleteData(t.log, uid));
    expect(t.log, ['reauth:apple.com', 'data:uid-1', 'delete-user']);
  });

  test('data deletion refused → deleteFailed, the user is kept', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final t = _setUp(['apple.com']);
    await expectLater(
      t.service.deleteAccount(
        deleteData: (_) async => throw FirebaseException(
            plugin: 'cloud_firestore', code: 'permission-denied'),
      ),
      throwsA(isA<AuthException>()
          .having((e) => e.failure, 'failure', AuthFailure.deleteFailed)
          .having((e) => e.detail, 'detail', 'permission-denied')),
    );
    expect(t.log, ['reauth:apple.com']);
  });

  test('offline data deletion times out, the user is kept', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final t = _setUp(['apple.com']);
    await expectLater(
      t.service.deleteAccount(
          deleteData: (_) async => throw TimeoutException('offline')),
      throwsA(isA<TimeoutException>()),
    );
    expect(t.log, ['reauth:apple.com']);
  });

  test('user already gone on the server → local sign-out, no error', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final t = _setUp(['apple.com']);
    t.user.deleteError = FirebaseAuthException(code: 'user-not-found');
    await t.service.deleteAccount(deleteData: (uid) => _deleteData(t.log, uid));
    expect(t.log.last, 'sign-out');
    expect(t.auth.currentUser, isNull);
  });

  test('user deletion fails → deleteFailed with the code', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final t = _setUp(['apple.com']);
    t.user.deleteError = FirebaseAuthException(code: 'too-many-requests');
    await expectLater(
      t.service.deleteAccount(deleteData: (uid) => _deleteData(t.log, uid)),
      throwsA(isA<AuthException>()
          .having((e) => e.failure, 'failure', AuthFailure.deleteFailed)
          .having((e) => e.detail, 'detail', 'too-many-requests')),
    );
  });
}
