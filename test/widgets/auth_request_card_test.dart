import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
  Locale locale = const Locale('en'),
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  final taps = _Taps();
  await tester.pumpWidget(MaterialApp(
    // The app's themes: Material 3, blue seed.
    theme: ThemeData(colorSchemeSeed: Colors.blue, brightness: brightness),
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
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
      ),
    ),
  ));
  return taps;
}

/// A phone [width] pt wide (3x).
void _phone(WidgetTester tester, double width) {
  tester.view.physicalSize = Size(width * 3, 900 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

Rect _button(WidgetTester tester, String id) =>
    tester.getRect(find.bySemanticsIdentifier(id));

/// The card's frame (its ContentCard border).
BorderSide _frame(WidgetTester tester) {
  final container = tester.widget<Container>(find
      .descendant(
          of: find.byType(AuthRequestCard), matching: find.byType(Container))
      .first);
  final shape = (container.decoration! as ShapeDecoration).shape
      as RoundedSuperellipseBorder;
  return shape.side;
}

ColorScheme _cs(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(AuthRequestCard))).colorScheme;

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

  group('AuthRequestCard (look)', () {
    testWidgets('the trust frame is toned down but keeps its colours',
        (tester) async {
      await _pump(tester, _request(), ipTrust: true);
      var frame = _frame(tester);
      expect(frame.width, AuthRequestCard.trustFrameWidth);
      expect(frame.width, lessThan(1.5), reason: 'thinner than before');
      expect(frame.color, kTrustGreen.withValues(alpha: 0.5));

      await _pump(tester, _request(), ipTrust: false);
      frame = _frame(tester);
      expect(frame.width, 1);
      expect(frame.color, _cs(tester).error.withValues(alpha: 0.5));
      // The status stays in words.
      expect(find.text(_l.ipDenied), findsOneWidget);

      await _pump(tester, _request());
      frame = _frame(tester);
      expect(frame.width, 1);
      expect(frame.color, _cs(tester).outlineVariant.withValues(alpha: 0.6));
      await _dispose(tester);
    });

    for (final brightness in Brightness.values) {
      testWidgets('the accent is Approve\'s alone (${brightness.name})',
          (tester) async {
        await _pump(tester, _request(), brightness: brightness);
        final cs = _cs(tester);
        final context = tester.element(find.text(_l.deny));
        // Deny: neutral text on the outline.
        final deny = _denyButton(tester);
        expect(deny.style!.foregroundColor!.resolve({}), cs.onSurface);
        expect(DefaultTextStyle.of(context).style.color, cs.onSurface);
        // Approve: the accent fill.
        final approveContext = tester.element(find.text(_l.approve));
        final approveMaterial = tester.widget<Material>(find
            .ancestor(
                of: find.text(_l.approve), matching: find.byType(Material))
            .first);
        expect(approveMaterial.color, cs.primary);
        expect(DefaultTextStyle.of(approveContext).style.color, cs.onPrimary);
        // Fingerprint words: neutral chips.
        final chip = tester.widget<Container>(find
            .ancestor(
                of: find.text('childless'), matching: find.byType(Container))
            .first);
        final chipColor = (chip.decoration! as BoxDecoration).color;
        expect(chipColor, cs.surfaceContainerHighest);
        expect(chipColor, isNot(cs.primaryContainer));
        await _dispose(tester);
      });
    }

    testWidgets('normal text: Deny and Approve side by side at the end',
        (tester) async {
      _phone(tester, 402);
      await _pump(tester, _request());
      final deny = _button(tester, 'btn_deny');
      final approve = _button(tester, 'btn_approve');
      final render = tester.renderObject<RenderDecisionButtons>(
          find.byWidgetPredicate(
              (w) => w.runtimeType.toString() == '_DecisionButtons'));
      expect(render.stacked, isFalse);
      expect(deny.center.dy, moreOrLessEquals(approve.center.dy));
      expect(deny.right, lessThan(approve.left));
      // Card 20-pt margin + 1-pt frame + 16-pt padding.
      expect(approve.right, moreOrLessEquals(402 - 37));
      expect(deny.height, greaterThanOrEqualTo(48));
      expect(approve.height, greaterThanOrEqualTo(48));
      await _dispose(tester);
    });

    testWidgets('RTL: the pair sits at the end on the left, mirrored',
        (tester) async {
      _phone(tester, 402);
      await _pump(tester, _request(), locale: const Locale('ar'));
      final deny = _button(tester, 'btn_deny');
      final approve = _button(tester, 'btn_approve');
      expect(approve.left, moreOrLessEquals(37));
      expect(approve.right, lessThan(deny.left));
      await _dispose(tester);
    });

    for (final locale in const [Locale('en'), Locale('ru'), Locale('ar')]) {
      testWidgets(
          'text scale 2.0 at 320 pt: the buttons stack full width, no '
          'overflow (${locale.languageCode})', (tester) async {
        _phone(tester, 320);
        final taps = await _pump(tester, _request(),
            locale: locale, textScale: 2, ipTrust: true);
        expect(tester.takeException(), isNull, reason: 'no overflow');
        final render = tester.renderObject<RenderDecisionButtons>(
            find.byWidgetPredicate(
                (w) => w.runtimeType.toString() == '_DecisionButtons'));
        expect(render.stacked, isTrue);
        final deny = _button(tester, 'btn_deny');
        final approve = _button(tester, 'btn_approve');
        // Same order as the row: Deny, then Approve under it.
        expect(approve.top, greaterThan(deny.bottom));
        for (final b in [deny, approve]) {
          expect(b.left, moreOrLessEquals(37));
          expect(b.right, moreOrLessEquals(320 - 37));
          expect(b.height, greaterThanOrEqualTo(48));
        }
        // The labels are not clipped.
        for (final label in [_l.deny, _l.approve]) {
          final text = find.text(label == _l.deny
              ? lookupAppLocalizations(locale).deny
              : lookupAppLocalizations(locale).approve);
          final paragraph = tester.renderObject<RenderParagraph>(text);
          expect(paragraph.didExceedMaxLines, isFalse);
        }
        await tester.tap(find.bySemanticsIdentifier('btn_approve'));
        await tester.tap(find.bySemanticsIdentifier('btn_deny'));
        expect(taps.approve, 1);
        expect(taps.deny, 1);
        await _dispose(tester);
      });
    }
  });
}
