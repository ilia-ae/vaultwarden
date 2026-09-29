import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/app.dart';
import 'package:vault_approver/demo_fixtures.dart';
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/models/auth_request.dart';
import 'package:vault_approver/providers/auth_requests_provider.dart';
import 'package:vault_approver/providers/session_provider.dart';
import 'package:vault_approver/services/secure_storage_service.dart';
import 'package:vault_approver/services/vault_api.dart';
import 'package:vault_approver/utils/constants.dart';

import 'provider_fakes.dart';

/// Keeps a provider alive (like a widget watching it) for the test.
ProviderSubscription<T> keepAlive<T>(
  ProviderContainer c,
  ProviderListenable<T> provider,
) =>
    c.listen<T>(provider, (_, __) {});

void main() {
  tearDown(() => demoRuntime.value = false);

  group('logout (A13, F6, F7, F13)', () {
    testWidgets('stops polling, resets services, clears session data only',
        (tester) async {
      final h = await Harness.create();
      await h.signIn();
      keepAlive(h.container, authRequestsProvider);
      await h.container.read(authRequestsProvider.future);
      expect(h.api.pendingCalls, 1);
      expect(h.hub.connects, hasLength(1));
      final deviceId = await h.storage.getOrCreateDeviceId();
      await h.storage.saveTwoFactorRememberToken(
          serverUrl: kServer, email: kEmail, token: 'remember');

      await h.container.read(sessionProvider.notifier).logout();

      expect(h.container.read(sessionProvider).value, isNull);
      expect(h.container.read(userKeyProvider), isNull);
      expect(h.api.resets, greaterThanOrEqualTo(1));
      expect(h.hub.resets, greaterThanOrEqualTo(1));
      expect(h.container.read(sessionEndNoticeProvider), isNull);

      // No poll after logout, however long we wait.
      final calls = h.api.pendingCalls;
      await tester.pump(const Duration(minutes: 2));
      expect(h.api.pendingCalls, calls);

      final keychain = await h.keychain();
      expect(keychain[SecureStorageService.keySession], isNull);
      expect(keychain[SecureStorageService.keyEncryptedUserKey], isNull);
      expect(keychain[SecureStorageService.keyBiometricStorageKey], isNull);
      // device_id and client certificates survive (F6, A13).
      expect(keychain[SecureStorageService.keyDeviceId], deviceId);
      expect(keychain['client_cert|$kServer'], isNotNull);
      expect(keychain['client_ca|$kServer'], isNotNull);
      // A user logout forgets 2FA remember tokens.
      expect(
          keychain.keys.where((k) =>
              k.startsWith(SecureStorageService.twoFactorRememberPrefix)),
          isEmpty);
      h.dispose();
    });

    test('history is per account and deleted on logout (F13)', () async {
      final h = await Harness.create();
      await h.signIn();
      h.api.pending = [testRequest('r1')];
      keepAlive(h.container, authRequestsProvider);
      keepAlive(h.container, historyProvider);
      final requests = await h.container.read(authRequestsProvider.future);
      await h.container.read(historyProvider.notifier).loaded;

      await h.container
          .read(authRequestsProvider.notifier)
          .approve(requests[0]);
      expect(h.api.calls, contains('respond:r1:true'));
      expect(h.container.read(historyProvider), hasLength(1));
      final historyKey = SecureStorageService.historyKey(kServer, kEmail);
      expect((await h.keychain())[historyKey], contains('r1'));

      await h.container.read(sessionProvider.notifier).logout();
      expect(h.container.read(historyProvider), isEmpty);
      final keychain = await h.keychain();
      expect(
          keychain.keys.where(
              (k) => k.startsWith(SecureStorageService.historyKeyPrefix)),
          isEmpty);
      h.dispose();
    });
  });

  group('history of older builds (F13 migration)', () {
    final now = DateTime.now();
    HistoryEntry legacy(String id, Duration age) => HistoryEntry(
          requestId: id,
          deviceType: 'Chrome',
          ipAddress: '203.0.113.7',
          approved: true,
          respondedAt: now.subtract(age),
          requestCreatedAt: now.subtract(age),
        );
    String legacyJson() => jsonEncode([
          legacy('recent', const Duration(days: 1)).toJson(),
          legacy('stale', const Duration(days: 40)).toJson(),
        ]);

    test('is migrated once into the session that survived the update',
        () async {
      final h = await Harness.create();
      await h.raw.write(
          key: SecureStorageService.historyKeyPrefix, value: legacyJson());
      await h.signIn();
      keepAlive(h.container, historyProvider);
      await h.container.read(historyProvider.notifier).loaded;

      final history = h.container.read(historyProvider);
      expect(history.map((e) => e.requestId), ['recent']);
      expect(ipTrustStatus('203.0.113.7', history), isTrue);
      final keychain = await h.keychain();
      expect(keychain[SecureStorageService.historyKeyPrefix], isNull);
      expect(keychain[SecureStorageService.historyKey(kServer, kEmail)],
          contains('recent'));
      h.dispose();
    });

    test('a new sign-in never inherits it', () async {
      final h = await Harness.create();
      await h.raw.write(
          key: SecureStorageService.historyKeyPrefix, value: legacyJson());
      final ok = {
        'access_token': 'at',
        'refresh_token': 'rt',
        'expires_in': 3600,
        'Key': await h.protectedUserKey(),
      };
      h.api.onLogin = (_) => ok;
      await h.container.read(sessionProvider.notifier).setup(
            serverUrl: kServer,
            email: kEmail,
            masterPassword: kPassword,
            onProgress: (_) {},
          );
      keepAlive(h.container, historyProvider);
      await h.container.read(historyProvider.notifier).loaded;
      expect(h.container.read(historyProvider), isEmpty);
      expect(
          (await h.keychain())[SecureStorageService.historyKeyPrefix], isNull);
      h.dispose();
    });
  });

  group('runtime demo isolation (F7, R4)', () {
    testWidgets('real → logout → demo makes zero API calls and leaves storage',
        (tester) async {
      final h = await Harness.create();
      await h.signIn();
      keepAlive(h.container, authRequestsProvider);
      await h.container.read(authRequestsProvider.future);
      await h.container.read(sessionProvider.notifier).logout();
      final before = await h.keychain();
      final callsBefore = h.api.serverCalls.length;
      final connectsBefore = h.hub.connects.length;

      h.container.read(sessionProvider.notifier).enterRuntimeDemo();
      expect(demoRuntime.value, isTrue);
      final demo = ProviderContainer(
        parent: h.container,
        overrides: runtimeDemoOverrides(),
      );
      keepAlive(demo, authRequestsProvider);
      keepAlive(demo, historyProvider);
      expect((await demo.read(sessionProvider.future))?.email,
          demoSession().email);
      expect(demo.read(isLockedProvider), isFalse);
      final fixtures = await demo.read(authRequestsProvider.future);
      expect(fixtures, isNotEmpty);

      final notifier = demo.read(authRequestsProvider.notifier);
      notifier.resume();
      notifier.addDemoRequest();
      final list = demo.read(authRequestsProvider).value!;
      await notifier.approve(list.first);
      await notifier.deny(list.last);
      await notifier.refresh();
      await tester.pump(const Duration(minutes: 2));

      expect(h.api.serverCalls.length, callsBefore);
      expect(h.hub.connects.length, connectsBefore);
      // Demo history stays in the demo container.
      expect(demo.read(historyProvider).length, greaterThan(5));
      expect(h.container.read(historyProvider), isEmpty);

      // Leaving the demo: no storage access at all (never clearAll, R4).
      await demo.read(sessionProvider.notifier).logout();
      expect(demoRuntime.value, isFalse);
      h.container.read(sessionProvider.notifier).resetLiveState();
      demo.dispose();
      // Let the invalidated providers rebuild (zero-delay scheduler task).
      await tester.pump(Duration.zero);
      expect(await h.keychain(), before);
      expect(h.container.read(sessionProvider).value, isNull);
      h.dispose();
    });

    test('demo → logout → real login connects the WebSocket', () async {
      final h = await Harness.create();
      final protectedKey = await h.protectedUserKey();
      h.api.onLogin = (_) => {
            'access_token': 'at-real',
            'refresh_token': 'rt-real',
            'expires_in': 7200,
            'Key': protectedKey,
          };

      h.container.read(sessionProvider.notifier).enterRuntimeDemo();
      final demo = ProviderContainer(
        parent: h.container,
        overrides: runtimeDemoOverrides(),
      );
      keepAlive(demo, authRequestsProvider);
      final fixtures = await demo.read(authRequestsProvider.future);
      await demo.read(authRequestsProvider.notifier).approve(fixtures.first);
      await demo.read(sessionProvider.notifier).logout();
      h.container.read(sessionProvider.notifier).resetLiveState();
      demo.dispose();
      expect(h.hub.connects, isEmpty);

      final userKey = await h.container.read(sessionProvider.notifier).setup(
            serverUrl: '$kServer/',
            email: kEmail,
            masterPassword: kPassword,
            onProgress: (_) {},
          );
      expect(userKey, Harness.userKey);
      final session = h.container.read(sessionProvider).value!;
      expect(session.serverUrl, kServer); // normalised base URL
      expect(session.accessToken, 'at-real');

      keepAlive(h.container, authRequestsProvider);
      keepAlive(h.container, historyProvider);
      await h.container.read(authRequestsProvider.future);
      expect(h.hub.connects, hasLength(1));
      expect(h.hub.connects.single.baseUrl, kServer);
      expect(h.api.pendingCalls, 1);
      // No demo entry reached the real history.
      await h.container.read(historyProvider.notifier).loaded;
      expect(h.container.read(historyProvider), isEmpty);
      h.dispose();
    });

    test('demo IPs come only from RFC 5737 documentation ranges (F13)', () {
      final ips = [
        ...demoPendingRequests().map((r) => r.requestIpAddress),
        ...demoHistoryEntries().map((e) => e.ipAddress),
        for (var i = 0; i < 200; i++) demoRandomPending().requestIpAddress,
      ];
      final doc = RegExp(r'^(192\.0\.2|198\.51\.100|203\.0\.113)\.\d{1,3}$');
      for (final ip in ips) {
        expect(doc.hasMatch(ip), isTrue, reason: ip);
      }
    });
  });

  group('server ends the session (F11, A9)', () {
    Future<Harness> signedInWithRequests() async {
      final h = await Harness.create();
      await h.signIn();
      await h.storage.saveTwoFactorRememberToken(
          serverUrl: kServer, email: kEmail, token: 'remember');
      keepAlive(h.container, authRequestsProvider);
      await h.container.read(authRequestsProvider.future);
      return h;
    }

    Future<void> expectForcedLogout(
      WidgetTester tester,
      Harness h,
      SessionEndNotice notice,
    ) async {
      expect(h.container.read(sessionProvider).value, isNull);
      expect(h.container.read(sessionEndNoticeProvider), notice);
      expect(h.api.resets, greaterThanOrEqualTo(1));
      expect(h.hub.resets, greaterThanOrEqualTo(1));
      final keychain = await h.keychain();
      expect(keychain[SecureStorageService.keySession], isNull);
      expect(keychain[SecureStorageService.keyEncryptedUserKey], isNull);
      expect(keychain[SecureStorageService.keyDeviceId], isNotNull);
      expect(keychain['client_cert|$kServer'], isNotNull);
      // The remember token survives a forced logout (quick re-login, A6).
      expect(
          keychain[SecureStorageService.twoFactorRememberKey(kServer, kEmail)],
          'remember');
      final calls = h.api.pendingCalls;
      await tester.pump(const Duration(minutes: 2));
      expect(h.api.pendingCalls, calls, reason: 'polling must stop');
    }

    testWidgets('dead refresh token → setup screen with notice',
        (tester) async {
      final h = await signedInWithRequests();
      h.api.simulateSessionEnded();
      await tester.pump();
      await tester.pump();
      await expectForcedLogout(tester, h, SessionEndNotice.sessionEnded);
      h.dispose();
    });

    testWidgets('a poll that hits SessionEnded also ends the session',
        (tester) async {
      final h = await signedInWithRequests();
      h.api.pendingError = const SessionEndedException(
          reason: SessionEndReason.unauthorizedAfterRefreshFailure);
      await tester.pump(const Duration(seconds: 15)); // one poll tick
      await tester.pump();
      await expectForcedLogout(tester, h, SessionEndNotice.sessionEnded);
      h.dispose();
    });

    testWidgets('a dead session on the first fetch ends it too',
        (tester) async {
      final h = await Harness.create();
      await h.signIn();
      await h.storage.saveTwoFactorRememberToken(
          serverUrl: kServer, email: kEmail, token: 'remember');
      h.api.pendingError = const SessionEndedException(
          reason: SessionEndReason.refreshTokenRejected);
      keepAlive(h.container, authRequestsProvider);
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      await expectForcedLogout(tester, h, SessionEndNotice.sessionEnded);
      h.dispose();
    });

    testWidgets('hub LogOut (type 11) forces re-login (A9)', (tester) async {
      final h = await signedInWithRequests();
      h.hub.emit(kLogOutNotificationType);
      await tester.pump();
      await tester.pump();
      await expectForcedLogout(tester, h, SessionEndNotice.signedOutByServer);
      h.dispose();
    });

    testWidgets('hub LogOut with Reason 1 (key rotation) forces re-login',
        (tester) async {
      final h = await signedInWithRequests();
      h.hub.emit(kLogOutNotificationType, payload: {'Reason': 1});
      await tester.pump();
      await tester.pump();
      await expectForcedLogout(tester, h, SessionEndNotice.signedOutByServer);
      h.dispose();
    });

    testWidgets('hub LogOut with Reason 0 (KDF change) is ignored',
        (tester) async {
      final h = await signedInWithRequests();
      h.hub.emit(kLogOutNotificationType, payload: {'Reason': 0});
      await tester.pump();
      await tester.pump();
      expect(h.container.read(sessionProvider).value, isNotNull);
      expect(h.container.read(userKeyProvider), isNotNull);
      expect(h.container.read(sessionEndNoticeProvider), isNull);
      expect(h.api.resets, 0);
      expect(h.hub.resets, 0);
      h.dispose();
    });
  });

  group('realtime and polling', () {
    testWidgets(
        'a refreshed session reaches the provider, keychain and hub (A5)',
        (tester) async {
      final h = await Harness.create();
      await h.signIn();
      keepAlive(h.container, authRequestsProvider);
      await h.container.read(authRequestsProvider.future);

      h.api.simulateRefresh(
          testSession(accessToken: 'at-2', refreshToken: 'rt-2'));
      await tester.pump();

      expect(h.container.read(sessionProvider).value!.accessToken, 'at-2');
      expect((await h.storage.loadSession())!.accessToken, 'at-2');
      expect(h.hub.tokens, ['at-2']);
      // An account-level provider is not rebuilt by a token refresh.
      expect(h.hub.connects, hasLength(1));
      expect(h.api.pendingCalls, 1);

      // A stale event (session replaced meanwhile) is ignored.
      h.api.simulateRefresh(testSession(accessToken: 'at-3'));
      h.api.configure(kServer, testSession(accessToken: 'at-4'));
      await tester.pump();
      expect(h.container.read(sessionProvider).value!.accessToken, 'at-2');
      h.dispose();
    });

    testWidgets('hub type 15/16 trigger a silent refresh (A10)',
        (tester) async {
      final h = await Harness.create();
      await h.signIn();
      keepAlive(h.container, authRequestsProvider);
      await h.container.read(authRequestsProvider.future);
      h.hub.emit(kAuthRequestNotificationType);
      await tester.pump();
      h.hub.emit(kAuthRequestResponseNotificationType);
      await tester.pump();
      expect(h.api.pendingCalls, 3);
      h.dispose();
    });

    testWidgets('changing pollInterval restarts the timer at once (A11)',
        (tester) async {
      final h = await Harness.create();
      await h.signIn();
      keepAlive(h.container, authRequestsProvider);
      await h.container.read(authRequestsProvider.future);
      expect(h.api.pendingCalls, 1);

      await tester.pump(const Duration(seconds: 10));
      expect(h.api.pendingCalls, 1); // 15 s default not reached

      h.container.read(pollIntervalProvider.notifier).state = 5;
      await tester.pump(const Duration(seconds: 5));
      expect(h.api.pendingCalls, 2);
      await tester.pump(const Duration(seconds: 5));
      expect(h.api.pendingCalls, 3);

      // A corrupt value never polls faster than every 5 s (R2).
      h.container.read(pollIntervalProvider.notifier).state = 0;
      await tester.pump(const Duration(seconds: 4));
      expect(h.api.pendingCalls, 3);
      await tester.pump(const Duration(seconds: 1));
      expect(h.api.pendingCalls, 4);
      h.dispose();
    });

    testWidgets('401 that survives the refresh stops polling (F11)',
        (tester) async {
      final h = await Harness.create();
      await h.signIn();
      keepAlive(h.container, authRequestsProvider);
      final notifier = h.container.read(authRequestsProvider.notifier);
      await h.container.read(authRequestsProvider.future);
      expect(h.api.pendingCalls, 1);

      h.api.pendingError = const ServerException(statusCode: 401);
      await tester.pump(const Duration(seconds: 15)); // one poll tick
      expect(h.api.pendingCalls, 2);
      expect(
          h.container.read(authRequestsProvider).error, isA<ServerException>());
      // No further ticks (each would refresh the token on the server).
      await tester.pump(const Duration(minutes: 2));
      expect(h.api.pendingCalls, 2);
      // The session itself is kept.
      expect(h.container.read(sessionProvider).value, isNotNull);

      // A manual refresh that works again restarts polling.
      h.api.pendingError = null;
      await notifier.refresh();
      expect(h.api.pendingCalls, 3);
      await tester.pump(const Duration(seconds: 15));
      expect(h.api.pendingCalls, 4);
      h.dispose();
    });

    testWidgets('one hub connect per build; resume reconnects only after pause',
        (tester) async {
      final h = await Harness.create(prefs: {'settings.poll_interval': 60});
      await h.signIn();
      keepAlive(h.container, authRequestsProvider);
      final notifier = h.container.read(authRequestsProvider.notifier);
      notifier.resume(); // RequestsScreen.initState right after the build
      await h.container.read(authRequestsProvider.future);
      expect(h.hub.connects, hasLength(1));
      expect(h.hub.resumes, 0);
      expect(h.api.pendingCalls, 1, reason: 'no burst during the first fetch');

      notifier.pause();
      notifier.resume();
      await tester.pump();
      expect(h.hub.pauses, 1);
      expect(h.hub.resumes, 1);
      expect(h.hub.connects, hasLength(1));
      h.dispose();
    });

    testWidgets(
        'refresh burst stops at the first success; pause cancels it (R1)',
        (tester) async {
      final h = await Harness.create(prefs: {'settings.poll_interval': 60});
      await h.signIn();
      keepAlive(h.container, authRequestsProvider);
      final notifier = h.container.read(authRequestsProvider.notifier);
      await h.container.read(authRequestsProvider.future);
      expect(h.api.pendingCalls, 1);

      notifier.resume();
      await tester.pump();
      expect(h.api.pendingCalls, 2);
      await tester.pump(const Duration(seconds: 20));
      expect(h.api.pendingCalls, 2, reason: 'stopped after the first success');

      h.api.pendingError = DioException(
        requestOptions: RequestOptions(path: '/api/auth-requests/pending'),
        type: DioExceptionType.connectionError,
      );
      notifier.resume();
      await tester.pump();
      expect(h.api.pendingCalls, 3);
      notifier.pause();
      await tester.pump(const Duration(seconds: 30));
      expect(h.api.pendingCalls, 3, reason: 'pause cancels the burst');

      // A newer resume supersedes the running burst (no stacking).
      notifier.resume();
      await tester.pump();
      notifier.resume();
      await tester.pump();
      final afterTwoResumes = h.api.pendingCalls;
      await tester.pump(AuthRequestsNotifier.burstDelay);
      expect(h.api.pendingCalls, afterTwoResumes + 1);
      notifier.pause();
      h.dispose();
    });
  });

  group('resume burst and the mTLS heuristic (F1)', () {
    testWidgets('a maybe-mTLS reset is retried; a definitive alert is shown',
        (tester) async {
      final h = await Harness.create(prefs: {'settings.poll_interval': 60});
      await h.signIn();
      keepAlive(h.container, authRequestsProvider);
      final notifier = h.container.read(authRequestsProvider.notifier);
      await h.container.read(authRequestsProvider.future);
      expect(h.api.pendingCalls, 1);

      // A stale connection after resume looks like "closed during TLS":
      // retried like a network error, the list stays.
      h.api.pendingError = const ClientCertificateRequiredException(
        definitive: false,
      );
      notifier.resume();
      await tester.pump();
      expect(h.api.pendingCalls, 2);
      expect(h.container.read(authRequestsProvider).hasError, isFalse);
      h.api.pendingError = null;
      await tester.pump(AuthRequestsNotifier.burstDelay);
      expect(h.api.pendingCalls, 3);
      expect(h.container.read(authRequestsProvider).hasError, isFalse);

      // An explicit TLS alert is shown at once.
      h.api.pendingError = const ClientCertificateRequiredException();
      notifier.resume();
      await tester.pump();
      expect(h.api.pendingCalls, 4);
      expect(h.container.read(authRequestsProvider).error,
          isA<ClientCertificateRequiredException>());
      await tester.pump(AuthRequestsNotifier.burstDelay * 3);
      expect(h.api.pendingCalls, 4);
      notifier.pause();
      h.dispose();
    });
  });

  group('actionable window and approve guards (F5, A1)', () {
    testWidgets('a request is hidden when it leaves the 5-minute window',
        (tester) async {
      // Local clock that advances with the test's fake time.
      final realStart = DateTime.now();
      final fakeStart = tester.binding.clock.now();
      DateTime now() =>
          realStart.add(tester.binding.clock.now().difference(fakeStart));
      final h = await Harness.create(
        prefs: {'settings.poll_interval': 60},
        overrides: [requestClockProvider.overrideWithValue(now)],
      );
      await h.signIn();
      h.api.pending = [
        testRequest('old', age: const Duration(minutes: 4, seconds: 58)),
        testRequest('new'),
      ];
      keepAlive(h.container, authRequestsProvider);
      final first = await h.container.read(authRequestsProvider.future);
      expect(first.map((r) => r.id), ['new', 'old']);

      await tester.pump(const Duration(seconds: 3));
      expect(h.container.read(authRequestsProvider).value!.map((r) => r.id),
          ['new']);
      h.dispose();
    });

    test('expired or phrase-less requests are never approved', () async {
      final h = await Harness.create();
      await h.signIn();
      keepAlive(h.container, authRequestsProvider);
      await h.container.read(authRequestsProvider.future);
      final notifier = h.container.read(authRequestsProvider.notifier);

      await expectLater(
        notifier.approve(testRequest('x', age: const Duration(minutes: 6))),
        throwsA(isA<AuthRequestExpiredException>()),
      );
      await expectLater(
        notifier.approve(testRequest('y', fingerprint: null)),
        throwsA(isA<FingerprintUnavailableException>()),
      );
      expect(h.api.calls.where((c) => c.startsWith('respond')), isEmpty);
      h.dispose();
    });
  });

  group('2FA remember token (A6)', () {
    Future<Harness> withRememberToken() async {
      final h = await Harness.create();
      await h.storage.saveTwoFactorRememberToken(
          serverUrl: kServer, email: kEmail, token: 'remember-1');
      return h;
    }

    Future<Map<String, dynamic>> tokenResponse(Harness h,
            {String? rememberToken}) async =>
        {
          'access_token': 'at',
          'refresh_token': 'rt',
          'expires_in': 3600,
          'Key': await h.protectedUserKey(),
          if (rememberToken != null) 'TwoFactorToken': rememberToken,
        };

    Future<void> setup(Harness h, {String? code, int? provider}) =>
        h.container.read(sessionProvider.notifier).setup(
              serverUrl: kServer,
              email: kEmail,
              masterPassword: kPassword,
              onProgress: (_) {},
              twoFactorToken: code,
              twoFactorProvider: provider,
            );

    test('a stored token is sent as provider 5', () async {
      final h = await withRememberToken();
      final ok = await tokenResponse(h);
      h.api.onLogin = (_) => ok;
      await setup(h);
      expect(h.api.loginCalls, hasLength(1));
      expect(h.api.loginCalls.single['twoFactorProvider'],
          kTwoFactorProviderRemember);
      expect(h.api.loginCalls.single['twoFactorToken'], 'remember-1');
      expect(h.api.loginCalls.single['twoFactorRemember'], isFalse);
      h.dispose();
    });

    test('a rejected token is deleted and 2FA surfaced — never looped',
        () async {
      final h = await withRememberToken();
      final ok = await tokenResponse(h, rememberToken: 'remember-2');
      h.api.onLogin = (call) {
        if (call['twoFactorProvider'] == kTwoFactorProviderRemember ||
            call['twoFactorToken'] == null) {
          throw const TwoFactorRequiredException(availableProviders: [0, 1]);
        }
        return ok;
      };

      await expectLater(setup(h), throwsA(isA<TwoFactorRequiredException>()));
      expect(h.api.loginCalls, hasLength(1));
      expect(
          await h.storage
              .loadTwoFactorRememberToken(serverUrl: kServer, email: kEmail),
          isNull);

      // The user enters a TOTP code; the new remember token is stored and
      // the KDF is not run again (keys cached for the pending login).
      await setup(h, code: '123456', provider: 0);
      expect(h.api.loginCalls, hasLength(2));
      expect(h.api.loginCalls.last['twoFactorProvider'], 0);
      expect(h.api.preloginCalls, 1);
      expect(
          await h.storage
              .loadTwoFactorRememberToken(serverUrl: kServer, email: kEmail),
          'remember-2');
      h.dispose();
    });
  });

  group('keychain errors (R4)', () {
    test('a keychain read error is an error state, not "logged out"', () async {
      final h = await Harness.create(storage: ThrowingSessionStorage());
      final sub = keepAlive(h.container, sessionProvider);
      await expectLater(h.container.read(sessionProvider.future),
          throwsA(isA<SecureStorageReadException>()));
      expect(h.container.read(sessionProvider).hasError, isTrue);
      expect(h.container.read(sessionProvider).valueOrNull, isNull);

      // "Log out" from the error screen leaves the error state for the
      // setup screen (the keychain wipe is best effort).
      await h.container.read(sessionProvider.notifier).logout();
      expect(h.container.read(sessionProvider).hasError, isFalse);
      expect(h.container.read(sessionProvider).valueOrNull, isNull);
      sub.close();
      h.dispose();
    });

    testWidgets('the error screen offers retry', (tester) async {
      var retries = 0;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: StorageErrorScreen(
          onRetry: () => retries++,
          onLogout: () async {},
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text("Can't read secure storage"), findsOneWidget);
      await tester.tap(find.text('Retry'));
      expect(retries, 1);
    });
  });

  group('trust colour (R5)', () {
    HistoryEntry entry(String ip, bool approved) => HistoryEntry(
          requestId: ip,
          deviceType: 'Chrome',
          ipAddress: ip,
          approved: approved,
          respondedAt: DateTime.now(),
          requestCreatedAt: DateTime.now(),
        );

    test('an empty IP never inherits a trust colour', () {
      final history = [entry('', true), entry(' ', false)];
      expect(ipTrustStatus('', history), isNull);
      expect(ipTrustStatus('  ', history), isNull);
    });

    test('a proxy / NAT / LAN address never gets a trust colour', () {
      const hops = [
        '172.24.0.1', // Docker gateway (proxy without X-Real-IP)
        '10.0.0.5',
        '192.168.1.20',
        '100.64.3.4', // CGNAT
        '127.0.0.1',
        '169.254.1.1',
        '::1',
        'fd00::1',
        'fe80::1',
        '::ffff:192.168.1.20',
      ];
      for (final ip in hops) {
        expect(isNonPublicIp(ip), isTrue, reason: ip);
        expect(ipTrustStatus(ip, [entry(ip, true)]), isNull, reason: ip);
      }
      for (final ip in [
        '203.0.113.9',
        '8.8.8.8',
        '172.32.0.1',
        '2001:db8::1',
        '::ffff:8.8.8.8',
        'not an ip',
      ]) {
        expect(isNonPublicIp(ip), isFalse, reason: ip);
      }
      expect(
          ipTrustStatus('2001:db8::1', [entry('2001:DB8::1', true)]), isTrue);
    });

    test('the latest answer for the same IP wins', () {
      final history = [entry('203.0.113.9', false), entry('203.0.113.9', true)];
      expect(ipTrustStatus('203.0.113.9', history), isFalse);
      expect(ipTrustStatus('198.51.100.1', history), isNull);
    });
  });

  test('AuthRequest fixtures used here are actionable', () {
    expect(testRequest('a').isActionable, isTrue);
    expect(AuthRequest.selectPending([testRequest('a')]).single.id, 'a');
  });
}
