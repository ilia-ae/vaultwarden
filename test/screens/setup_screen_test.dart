import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/demo_fixtures.dart';
import 'package:vault_approver/models/api_error.dart';
import 'package:vault_approver/models/server_environment.dart';
import 'package:vault_approver/providers/service_providers.dart';
import 'package:vault_approver/providers/session_provider.dart';
import 'package:vault_approver/screens/setup_screen.dart';
import 'package:vault_approver/widgets/client_cert_section.dart';

import '../providers/provider_fakes.dart';
import 'screen_harness.dart';

final _l = en();

class _Setup {
  _Setup(this.h, this.certs, this.picker);
  final Harness h;
  final FakeClientCertService certs;
  final FakePicker picker;
}

Future<_Setup> _pump(WidgetTester tester) async {
  // A phone-sized portrait screen.
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final certs = FakeClientCertService();
  final picker = FakePicker(null);
  final h = await Harness.create(overrides: [
    biometricServiceProvider.overrideWithValue(FakeBiometrics()),
    clientCertServiceProvider.overrideWithValue(certs),
    certificateFilePickerProvider.overrideWithValue(picker.call),
  ]);
  await tester.pumpWidget(testApp(h.container, const SetupScreen()));
  await tester.pump();
  return _Setup(h, certs, picker);
}

/// Lets the async login chain run without waiting for spinners to stop.
Future<void> _run(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _fillCredentials(
  WidgetTester tester, {
  String? serverUrl = kServer,
}) async {
  if (serverUrl != null) {
    await tester.enterText(
        find.widgetWithText(TextFormField, _l.serverUrlLabel), serverUrl);
  }
  await tester.enterText(
      find.widgetWithText(TextFormField, _l.emailLabel), kEmail);
  await tester.enterText(
      find.widgetWithText(TextFormField, _l.masterPasswordLabel), kPassword);
}

Future<void> _tapSetUp(WidgetTester tester) async {
  await tester.ensureVisible(find.text(_l.setUp));
  await tester.pump();
  await tester.tap(find.text(_l.setUp));
  await _run(tester);
}

Future<void> _enterCode(WidgetTester tester, String code) async {
  await tester.enterText(find.byType(TextField).last, code);
  await tester.pump();
}

Future<void> _verify(WidgetTester tester) async {
  await tester.tap(find.text(_l.verify));
  await _run(tester);
}

Future<void> _finish(WidgetTester tester, Harness h) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  h.dispose();
}

void main() {
  late String protectedKey;

  Map<String, dynamic> ok({String? rememberToken}) => {
        'access_token': 'at',
        'refresh_token': 'rt',
        'expires_in': 3600,
        'Key': protectedKey,
        if (rememberToken != null) 'TwoFactorToken': rememberToken,
      };

  group('server selector (F16)', () {
    for (final (label, env) in [
      ('bitwarden.eu', ServerEnvironment.eu),
      ('bitwarden.com', ServerEnvironment.us),
    ]) {
      testWidgets('$label → ${env.region.name} environment', (tester) async {
        final s = await _pump(tester);
        protectedKey = await s.h.protectedUserKey();
        s.h.api.onLogin = (_) => ok();

        // Self-hosted is the default: URL field and certificate row.
        expect(find.widgetWithText(TextFormField, _l.serverUrlLabel),
            findsOneWidget);
        expect(find.text(_l.clientCertTitle), findsOneWidget);

        await tester.tap(find.text(label));
        await tester.pump();
        expect(find.widgetWithText(TextFormField, _l.serverUrlLabel),
            findsNothing);
        expect(find.text(_l.clientCertTitle), findsNothing,
            reason: 'no mTLS for the cloud');
        expect(
          find.text(_l.serverCloudCaption(Uri.parse(env.baseUrl).host)),
          findsOneWidget,
        );

        await _fillCredentials(tester, serverUrl: null);
        await _tapSetUp(tester);

        expect(s.h.api.preloginUrls, [env.baseUrl]);
        expect(s.h.api.loginCalls.single['serverUrl'], env.baseUrl);
        final session = s.h.container.read(sessionProvider).value!;
        expect(session.serverUrl, env.baseUrl);
        expect(session.environment, env);
        expect(session.environment.apiUrl, env.apiUrl);
        await _finish(tester, s.h);
      });
    }

    testWidgets('self-hosted keeps the custom port', (tester) async {
      final s = await _pump(tester);
      protectedKey = await s.h.protectedUserKey();
      s.h.api.onLogin = (_) => ok();
      await _fillCredentials(tester, serverUrl: 'vault-test.example.org:2053/');
      await _tapSetUp(tester);
      final session = s.h.container.read(sessionProvider).value!;
      expect(session.serverUrl, 'https://vault-test.example.org:2053');
      expect(session.environment.region, ServerRegion.selfHosted);
      await _finish(tester, s.h);
    });
  });

  group('two-step login (F12, A4)', () {
    testWidgets(
        'picker → e-mail sends the code first; a wrong code keeps the dialog',
        (tester) async {
      final s = await _pump(tester);
      protectedKey = await s.h.protectedUserKey();
      s.h.api.onLogin = (call) {
        final token = call['twoFactorToken'];
        if (token == null) {
          throw const TwoFactorRequiredException(
            availableProviders: [0, 1],
            providerData: {
              1: {'Email': 'u***@example.com'},
            },
          );
        }
        if (token != '123456') {
          throw const InvalidTwoFactorCodeException(
              statusCode: 400, serverMessage: 'Token is invalid');
        }
        return ok(rememberToken: 'remember-me');
      };

      await _fillCredentials(tester);
      await _tapSetUp(tester);

      // Picker: both methods plus the recovery code.
      expect(find.text(_l.twoFactorChooseTitle), findsOneWidget);
      expect(find.text(_l.twoFactorProviderAuthenticator), findsOneWidget);
      expect(find.text(_l.twoFactorProviderRecoveryCode), findsOneWidget);
      expect(s.h.api.emailCodeRequests, isEmpty);

      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(_l.twoFactorProviderEmail),
      ));
      await _run(tester);
      // send-email-login ran before the code input appeared.
      expect(s.h.api.emailCodeRequests, [kServer]);
      expect(find.text(_l.codeSentTo('u***@example.com')), findsOneWidget);
      expect(find.text(_l.twoFactorPromptEmailTo('u***@example.com')),
          findsOneWidget);

      await tester.tap(find.text(_l.resendCode));
      await _run(tester);
      expect(s.h.api.emailCodeRequests, hasLength(2));

      await _enterCode(tester, '000000');
      await _verify(tester);
      expect(find.text(_l.errorInvalidTwoFactorCode), findsOneWidget);
      expect(find.text(_l.verify), findsOneWidget, reason: 'dialog reopened');

      await _enterCode(tester, '123456');
      await _verify(tester);
      expect(find.text(_l.verify), findsNothing);

      final logins = s.h.api.loginCalls;
      expect(
          logins.map((c) => c['twoFactorToken']), [null, '000000', '123456']);
      expect(logins.last['twoFactorProvider'], 1);
      expect(logins.last['twoFactorRemember'], isTrue);
      // The same device id on every attempt (F6).
      expect(logins.map((c) => c['deviceId']).toSet(), hasLength(1));
      expect(s.h.container.read(sessionProvider).value, isNotNull);
      // "Remember this device" stored the server's token (F12/A6).
      expect(
        await s.h.storage
            .loadTwoFactorRememberToken(serverUrl: kServer, email: kEmail),
        'remember-me',
      );
      // One KDF run for the whole flow (keys cached for the retries).
      expect(s.h.api.preloginCalls, 1);
      await _finish(tester, s.h);
    });

    testWidgets(
        'a single authenticator: code dialog directly, wrong code reopens, '
        '"remember" can be turned off', (tester) async {
      final s = await _pump(tester);
      protectedKey = await s.h.protectedUserKey();
      s.h.api.onLogin = (call) {
        final token = call['twoFactorToken'];
        if (token == null) {
          throw const TwoFactorRequiredException(availableProviders: [0]);
        }
        if (token != '654321') {
          throw const InvalidTwoFactorCodeException(
              statusCode: 400,
              serverMessage: 'Invalid TOTP code! Server time: 12:00 IP: x');
        }
        return ok();
      };

      await _fillCredentials(tester);
      await _tapSetUp(tester);
      expect(find.text(_l.twoFactorChooseTitle), findsNothing);
      expect(find.text(_l.twoFactorPrompt), findsOneWidget);

      await tester.tap(find.text(_l.twoFactorRemember));
      await tester.pump();

      // 6 digits submit on their own.
      await _enterCode(tester, '111111');
      await _run(tester);
      expect(find.text(_l.errorInvalidTwoFactorCode), findsOneWidget);
      expect(find.text(_l.twoFactorPrompt), findsOneWidget);

      await _enterCode(tester, '654321');
      await _run(tester);
      expect(find.text(_l.twoFactorPrompt), findsNothing);
      expect(s.h.api.loginCalls.last['twoFactorProvider'], 0);
      expect(s.h.api.loginCalls.last['twoFactorRemember'], isFalse);
      expect(s.h.container.read(sessionProvider).value, isNotNull);
      await _finish(tester, s.h);
    });

    testWidgets('unsupported methods only: explained, not selectable',
        (tester) async {
      final s = await _pump(tester);
      protectedKey = await s.h.protectedUserKey();
      s.h.api.onLogin = (_) =>
          throw const TwoFactorRequiredException(availableProviders: [7, 2]);

      await _fillCredentials(tester);
      await _tapSetUp(tester);
      expect(find.text(_l.twoFactorNoSupportedMethod), findsOneWidget);
      expect(find.text(_l.twoFactorProviderWebAuthn), findsOneWidget);
      expect(find.text(_l.twoFactorNotSupported), findsNWidgets(2));

      await tester.tap(find.text(_l.twoFactorProviderWebAuthn));
      await _run(tester);
      expect(find.text(_l.twoFactorChooseTitle), findsOneWidget,
          reason: 'disabled tile');

      await tester.tap(find.text(_l.cancel));
      await _run(tester);
      expect(s.h.api.loginCalls, hasLength(1));
      await _finish(tester, s.h);
    });

    testWidgets('recovery code is normalised and warned about', (tester) async {
      final s = await _pump(tester);
      protectedKey = await s.h.protectedUserKey();
      s.h.api.onLogin = (call) {
        if (call['twoFactorToken'] == null) {
          throw const TwoFactorRequiredException(availableProviders: [0, 1]);
        }
        return ok();
      };
      await _fillCredentials(tester);
      await _tapSetUp(tester);
      expect(find.text(_l.twoFactorProviderRecoveryCodeHint), findsOneWidget);
      await tester.tap(find.text(_l.twoFactorProviderRecoveryCode));
      await _run(tester);
      expect(find.text(_l.twoFactorPromptRecoveryCode), findsOneWidget);
      expect(find.text(_l.twoFactorRemember), findsNothing);
      await _enterCode(tester, 'ABCD EFGH 1234');
      await _verify(tester);
      expect(s.h.api.loginCalls.last['twoFactorToken'], 'abcdefgh1234');
      expect(s.h.api.loginCalls.last['twoFactorProvider'], 8);
      await _finish(tester, s.h);
    });
  });

  group('new-device verification (F6, A3)', () {
    testWidgets('wrong OTP keeps the dialog open; resend; right OTP signs in',
        (tester) async {
      final s = await _pump(tester);
      protectedKey = await s.h.protectedUserKey();
      s.h.api.onLogin = (call) {
        final otp = call['newDeviceOtp'];
        if (otp == null) {
          throw const NewDeviceVerificationRequiredException(
              statusCode: 400,
              serverMessage: 'new device verification required');
        }
        if (otp != '24680135') {
          throw const InvalidNewDeviceOtpException(
              statusCode: 400, serverMessage: 'invalid new device otp');
        }
        return ok();
      };

      await _fillCredentials(tester);
      await _tapSetUp(tester);
      expect(find.text(_l.newDeviceTitle), findsOneWidget);

      await _enterCode(tester, '111111');
      await _verify(tester);
      expect(find.text(_l.errorInvalidNewDeviceOtp), findsOneWidget);
      expect(find.text(_l.newDeviceTitle), findsOneWidget);

      await tester.tap(find.text(_l.resendCode));
      await _run(tester);
      expect(s.h.api.newDeviceOtpResends, hasLength(1));
      expect(find.text(_l.codeSent), findsOneWidget);

      await _enterCode(tester, '24680135');
      await _verify(tester);
      expect(find.text(_l.newDeviceTitle), findsNothing);
      final logins = s.h.api.loginCalls;
      expect(
          logins.map((c) => c['newDeviceOtp']), [null, '111111', '24680135']);
      expect(logins.map((c) => c['deviceId']).toSet(), hasLength(1));
      expect(s.h.api.newDeviceOtpResends.single, logins.first['deviceId']);
      expect(s.h.container.read(sessionProvider).value, isNotNull);
      await _finish(tester, s.h);
    });
  });

  group('errors (F1, F9)', () {
    testWidgets('a server demanding a client certificate says so',
        (tester) async {
      final s = await _pump(tester);
      s.h.api.onLogin = (_) => throw const ClientCertificateRequiredException();
      await _fillCredentials(tester);
      await _tapSetUp(tester);
      expect(find.text(_l.errorClientCertRequired), findsOneWidget);
      await _finish(tester, s.h);
    });

    testWidgets('429 shows the wait time', (tester) async {
      final s = await _pump(tester);
      s.h.api.onLogin = (_) => throw const RateLimitedException(
          statusCode: 429, retryAfter: Duration(seconds: 30));
      await _fillCredentials(tester);
      await _tapSetUp(tester);
      expect(find.text(_l.errorTooManyAttemptsWait(30)), findsOneWidget);
      await _finish(tester, s.h);
    });

    testWidgets("Vaultwarden's own message is shown (F9)", (tester) async {
      final s = await _pump(tester);
      s.h.api.onLogin = (_) => throw ApiException.fromResponse(400, {
            'message': 'This user has been disabled',
            'error': '',
            'error_description': '',
          });
      await _fillCredentials(tester);
      await _tapSetUp(tester);
      expect(find.text('This user has been disabled'), findsOneWidget);
      await _finish(tester, s.h);
    });

    testWidgets('an account without a user key gets a clear message (A8)',
        (tester) async {
      final s = await _pump(tester);
      s.h.api.onLogin = (_) => {
            'access_token': 'at',
            'refresh_token': 'rt',
            'expires_in': 3600,
          };
      await _fillCredentials(tester);
      await _tapSetUp(tester);
      expect(find.text(_l.errorMissingUserKey), findsOneWidget);
      expect(s.h.container.read(sessionProvider).value, isNull);
      await _finish(tester, s.h);
    });
  });

  group('client certificate on the setup screen (F1)', () {
    testWidgets('import validation errors, then a valid import',
        (tester) async {
      final s = await _pump(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, _l.serverUrlLabel),
        'https://vault-test.example.org:2053',
      );
      await tester.pump(const Duration(milliseconds: 500)); // debounce
      await tester.pump();

      s.picker.file = PickedCertificateFile(
        name: 'broken.p12',
        bytes: FakeClientCertService.badFile,
      );
      await tester.tap(find.text(_l.clientCertImport));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, _l.clientCertPasswordLabel), 'x');
      await tester.tap(find.text(_l.clientCertImportAction));
      await tester.pumpAndSettle();
      expect(find.text(_l.errorClientCertUnsupported), findsOneWidget);
      await tester.tap(find.text(_l.cancel));
      await tester.pumpAndSettle();

      s.picker.file = PickedCertificateFile(
        name: 'ilia-android.p12',
        bytes: Uint8List.fromList(List.filled(32, 7)),
      );
      await tester.tap(find.text(_l.clientCertImport));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.widgetWithText(TextField, _l.clientCertPasswordLabel), 'nope');
      await tester.tap(find.text(_l.clientCertImportAction));
      await tester.pumpAndSettle();
      expect(find.text(_l.errorClientCertBadPassword), findsOneWidget);

      await tester.enterText(
          find.widgetWithText(TextField, _l.clientCertPasswordLabel),
          FakeClientCertService.goodPassword);
      await tester.tap(find.text(_l.clientCertImportAction));
      await tester.pumpAndSettle();
      expect(s.certs.stored.keys, ['https://vault-test.example.org:2053']);
      expect(find.text('ilia-android'), findsOneWidget);
      await _finish(tester, s.h);
    });
  });

  group('layout', () {
    for (final locale in const [
      Locale('en'),
      Locale('ru'),
      Locale('ar'),
      Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    ]) {
      testWidgets('setup, picker and code dialog fit 320 pt ($locale)',
          (tester) async {
        tester.view.physicalSize = const Size(640, 1136);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
        final certs = FakeClientCertService();
        final h = await Harness.create(overrides: [
          biometricServiceProvider.overrideWithValue(FakeBiometrics()),
          clientCertServiceProvider.overrideWithValue(certs),
        ]);
        h.container.read(sessionEndNoticeProvider.notifier).state =
            SessionEndNotice.signedOutByServer;
        h.api.onLogin = (_) => throw const TwoFactorRequiredException(
              availableProviders: [0, 1, 3, 7],
            );
        await tester.pumpWidget(
            testApp(h.container, const SetupScreen(), locale: locale));
        await tester.pump();
        final fields = find.byType(TextFormField);
        await tester.enterText(fields.at(0), kServer);
        await tester.enterText(fields.at(1), kEmail);
        await tester.enterText(fields.at(2), kPassword);
        final submit = find.byType(FilledButton).last;
        await tester.ensureVisible(submit);
        await tester.pump();
        await tester.tap(submit);
        await _run(tester);
        expect(find.byType(AlertDialog), findsOneWidget);
        // The method list scrolls on a small screen.
        await tester.scrollUntilVisible(
          find.byIcon(Icons.usb),
          40,
          scrollable: find
              .descendant(
                of: find.byType(AlertDialog),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.tap(find.byIcon(Icons.usb));
        await _run(tester);
        expect(find.byType(AlertDialog), findsOneWidget);
        await _finish(tester, h);
      });
    }
  });

  testWidgets('a server-ended session is explained inline (F11)',
      (tester) async {
    final s = await _pump(tester);
    s.h.container.read(sessionEndNoticeProvider.notifier).state =
        SessionEndNotice.sessionEnded;
    await tester.pump();
    expect(find.text(_l.sessionEndedOnServer), findsOneWidget);
    await _finish(tester, s.h);
  });

  group('plain http (security review)', () {
    testWidgets('http:// to another host asks first; Cancel does not sign in',
        (tester) async {
      final s = await _pump(tester);
      protectedKey = await s.h.protectedUserKey();
      s.h.api.onLogin = (_) => ok();
      await _fillCredentials(tester, serverUrl: 'http://vault.example.com');
      await _tapSetUp(tester);
      expect(find.text(_l.plainHttpTitle), findsOneWidget);
      expect(s.h.api.serverCalls, isEmpty);

      await tester.tap(find.text(_l.cancel));
      await _run(tester);
      expect(s.h.api.serverCalls, isEmpty);
      expect(s.h.container.read(sessionProvider).value, isNull);

      await _tapSetUp(tester);
      await tester.tap(find.text(_l.plainHttpContinue));
      await _run(tester);
      expect(s.h.api.loginCalls, hasLength(1));
      expect(s.h.container.read(sessionProvider).value?.serverUrl,
          'http://vault.example.com');
      await _finish(tester, s.h);
    });

    testWidgets('http to this device does not ask', (tester) async {
      final s = await _pump(tester);
      protectedKey = await s.h.protectedUserKey();
      s.h.api.onLogin = (_) => ok();
      await _fillCredentials(tester, serverUrl: 'http://127.0.0.1:18080');
      await _tapSetUp(tester);
      expect(find.text(_l.plainHttpTitle), findsNothing);
      expect(s.h.api.loginCalls, hasLength(1));
      await _finish(tester, s.h);
    });
  });

  testWidgets('demo builds never sign in or touch certificates (F7)',
      (tester) async {
    demoRuntime.value = true;
    addTearDown(() => demoRuntime.value = false);
    final s = await _pump(tester);
    expect(find.text(_l.clientCertTitle), findsNothing);
    await _fillCredentials(tester);
    await _tapSetUp(tester);
    expect(s.h.api.serverCalls, isEmpty);
    await expectLater(
      s.h.container.read(sessionProvider.notifier).setup(
            serverUrl: kServer,
            email: kEmail,
            masterPassword: kPassword,
            onProgress: (_) {},
          ),
      throwsStateError,
    );
    expect(s.h.api.serverCalls, isEmpty);
    expect(await s.h.keychain(), isEmpty);
    await _finish(tester, s.h);
  });
}
