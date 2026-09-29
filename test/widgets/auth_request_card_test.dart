import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/models/auth_request.dart';
import 'package:vault_approver/widgets/auth_request_card.dart';

final _l = lookupAppLocalizations(const Locale('en'));
final _t0 = DateTime.utc(2026, 9, 27, 12);

AuthRequest _request({
  Duration age = const Duration(seconds: 10),
  String? fingerprint = 'childless-unfair-prowler-dropbox-designate',
  Duration serverClockOffset = Duration.zero,
  bool hasCreationDate = true,
}) =>
    AuthRequest(
      id: 'r1',
      publicKey: 'pk',
      requestDeviceType: 'Chrome',
      requestIpAddress: '203.0.113.7',
      creationDate: _t0.subtract(age),
      fingerprint: fingerprint,
      serverClockOffset: serverClockOffset,
      hasCreationDate: hasCreationDate,
    );

class _Taps {
  int approve = 0;
  int deny = 0;
}

Future<_Taps> _pump(
  WidgetTester tester,
  AuthRequest request, {
  bool? ipTrust,
  DateTime Function()? clock,
}) async {
  final taps = _Taps();
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: AuthRequestCard(
          request: request,
          ipTrust: ipTrust,
          clock: clock ?? () => _t0,
          onApprove: () => taps.approve++,
          onDeny: () => taps.deny++,
        ),
      ),
    ),
  ));
  return taps;
}

FilledButton _approveButton(WidgetTester tester) => tester.widget<FilledButton>(
      find.ancestor(
        of: find.text(_l.approve),
        matching: find.byType(FilledButton),
      ),
    );

OutlinedButton _denyButton(WidgetTester tester) =>
    tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text(_l.deny),
        matching: find.byType(OutlinedButton),
      ),
    );

Future<void> _dispose(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox());

void main() {
  test('formatCountdown', () {
    expect(formatCountdown(const Duration(minutes: 4, seconds: 5)), '4:05');
    expect(formatCountdown(const Duration(seconds: 59)), '0:59');
    expect(formatCountdown(Duration.zero), '0:00');
    expect(formatCountdown(const Duration(seconds: -3)), '0:00');
  });

  group('AuthRequestCard (F5 countdown)', () {
    testWidgets('a live request counts down and can be approved',
        (tester) async {
      final taps = await _pump(tester, _request());
      expect(find.text(_l.requestTimeLeft('4:50')), findsOneWidget);
      expect(find.text(_l.requestExpired), findsNothing);
      expect(_approveButton(tester).onPressed, isNotNull);
      await tester.tap(find.text(_l.approve));
      expect(taps.approve, 1);
      await _dispose(tester);
    });

    testWidgets('the countdown uses the server clock', (tester) async {
      // Server clock 2 min ahead: a request 1 min old locally is 3 min old.
      await _pump(
        tester,
        _request(
          age: const Duration(minutes: 1),
          serverClockOffset: const Duration(minutes: 2),
        ),
      );
      expect(find.text(_l.requestTimeLeft('2:00')), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('under a minute the countdown turns red', (tester) async {
      await _pump(
          tester, _request(age: const Duration(minutes: 4, seconds: 30)));
      final text = tester.widget<Text>(find.text(_l.requestTimeLeft('0:30')));
      final context = tester.element(find.byType(AuthRequestCard));
      expect(text.style?.color, Theme.of(context).colorScheme.error);
      await _dispose(tester);
    });

    testWidgets('ticks every second and disables Approve at expiry',
        (tester) async {
      var now = _t0;
      await _pump(
        tester,
        _request(age: const Duration(minutes: 4, seconds: 58)),
        clock: () => now,
      );
      expect(find.text(_l.requestTimeLeft('0:02')), findsOneWidget);
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(_l.requestTimeLeft('0:01')), findsOneWidget);
      expect(_approveButton(tester).onPressed, isNotNull);
      now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text(_l.requestExpired), findsOneWidget);
      expect(_approveButton(tester).onPressed, isNull);
      // The ticker stops once expired (no pending timers at dispose).
      await tester.pump(const Duration(seconds: 3));
      await _dispose(tester);
    });

    testWidgets('an expired card disables Approve (Deny stays)',
        (tester) async {
      final taps =
          await _pump(tester, _request(age: const Duration(minutes: 6)));
      expect(find.text(_l.requestExpired), findsOneWidget);
      expect(find.text(_l.requestExpiredHint), findsOneWidget);
      expect(_approveButton(tester).onPressed, isNull);
      await tester.tap(find.text(_l.approve), warnIfMissed: false);
      expect(taps.approve, 0);
      expect(_denyButton(tester).onPressed, isNotNull);
      await _dispose(tester);
    });

    testWidgets('a request without a creation date is never approvable (A2)',
        (tester) async {
      await _pump(tester, _request(hasCreationDate: false));
      expect(find.text(_l.requestExpired), findsOneWidget);
      expect(_approveButton(tester).onPressed, isNull);
      await _dispose(tester);
    });
  });

  group('AuthRequestCard (A1 fingerprint)', () {
    testWidgets('no fingerprint → cannot verify, Approve disabled',
        (tester) async {
      final taps = await _pump(tester, _request(fingerprint: null));
      expect(find.text(_l.fingerprintUnavailable), findsOneWidget);
      expect(find.text(_l.fingerprintLabel), findsNothing);
      expect(_approveButton(tester).onPressed, isNull);
      await tester.tap(find.text(_l.approve), warnIfMissed: false);
      expect(taps.approve, 0);
      expect(_denyButton(tester).onPressed, isNotNull);
      await _dispose(tester);
    });

    testWidgets('the phrase is shown word by word', (tester) async {
      await _pump(tester, _request());
      expect(find.text(_l.fingerprintLabel), findsOneWidget);
      for (final word in ['childless', 'unfair', 'prowler', 'dropbox']) {
        expect(find.text(word), findsOneWidget);
      }
      await _dispose(tester);
    });
  });

  group('AuthRequestCard (A7 trust status)', () {
    testWidgets('known IP', (tester) async {
      await _pump(tester, _request(), ipTrust: true);
      expect(find.text(_l.ipTrusted), findsOneWidget);
      expect(find.text(_l.ipDenied), findsNothing);
      await _dispose(tester);
    });

    testWidgets('denied IP', (tester) async {
      await _pump(tester, _request(), ipTrust: false);
      expect(find.text(_l.ipDenied), findsOneWidget);
      expect(find.text(_l.ipTrusted), findsNothing);
      await _dispose(tester);
    });

    testWidgets('unknown IP shows no status', (tester) async {
      await _pump(tester, _request());
      expect(find.text(_l.ipTrusted), findsNothing);
      expect(find.text(_l.ipDenied), findsNothing);
      await _dispose(tester);
    });

    testWidgets('the status is part of the IP line semantics', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester, _request(), ipTrust: true);
      // One node reads the address together with its trust status.
      expect(
        find.bySemanticsLabel(
            RegExp('203\\.0\\.113\\.7[\\s\\S]*${_l.ipTrusted}')),
        findsOneWidget,
      );
      handle.dispose();
      await _dispose(tester);
    });
  });
}
