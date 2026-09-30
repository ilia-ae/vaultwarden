// Safe-area insets of the tab bodies: in landscape the Dynamic Island /
// cutout sits at a side edge, so every list keeps MediaQuery padding
// left/right under its own gutters; the demo '+' FAB never covers the last
// card once the list is scrolled to its end.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/demo_fixtures.dart';
import 'package:vault_approver/glass.dart';
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';
import 'package:vault_approver/screens/pin/pin_widgets.dart';
import 'package:vault_approver/screens/requests_screen.dart';
import 'package:vault_approver/widgets/auth_request_card.dart';
import 'package:vault_approver/widgets/segmented_tabs.dart';

import 'pin/pin_harness.dart';

/// iPhone 18 Pro: 874 × 402 pt in landscape (island side inset 62 pt on
/// both sides, home indicator 21 pt), 402 × 874 in portrait.
void _landscape(WidgetTester tester) {
  tester.view.physicalSize = const Size(874 * 3, 402 * 3);
  tester.view.devicePixelRatio = 3;
  tester.view.padding =
      const FakeViewPadding(left: 62 * 3, right: 62 * 3, bottom: 21 * 3);
  addTearDown(tester.view.reset);
}

void _portrait(WidgetTester tester) {
  tester.view.physicalSize = const Size(402 * 3, 874 * 3);
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
  addTearDown(tester.view.reset);
}

Future<void> _pump(WidgetTester tester) async {
  mockPrivacyChannel(tester);
  await tester.pumpWidget(ProviderScope(
    // The runtime demo: fixture request and history, no network.
    overrides: [
      ...runtimeDemoOverrides(),
      pinComputeRunnerProvider.overrideWithValue(inlineRunner),
    ],
    child: const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale('en'),
      home: RequestsScreen(),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _tab(WidgetTester tester, String id) async {
  await tester.tap(byId(id));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pump();
  await tester.pump();
}

/// Scrolls the visible list of the current tab to its very end.
Future<void> _scrollToEnd(WidgetTester tester) async {
  final list = find.byType(ListView).hitTestable().first;
  final position = tester.state<ScrollableState>(
      find.descendant(of: list, matching: find.byType(Scrollable)).first);
  // A lazy list only estimates its extent (the short picker row first skews
  // the estimate): drag again until the end is really reached.
  for (var i = 0; i < 5; i++) {
    await tester.drag(list, const Offset(0, -3000));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    final p = position.position;
    if (p.pixels >= p.maxScrollExtent) break;
  }
  expect(position.position.pixels, position.position.maxScrollExtent);
}

/// A segmented picker's visible track, found by its first and last
/// segment: their columns plus the track's inset, at the track's height.
Rect _picker(WidgetTester tester, String firstId, String lastId) {
  final segments = tester
      .getRect(byId(firstId))
      .expandToInclude(tester.getRect(byId(lastId)));
  final track = tester.getRect(find.byKey(SegmentedTabs.trackKey));
  expect(segments.left - SegmentedTabs.inset, moreOrLessEquals(track.left));
  expect(segments.right + SegmentedTabs.inset, moreOrLessEquals(track.right));
  return track;
}

/// The painted card surface (inside the card's own margin).
Rect _surface(WidgetTester tester, Finder card) => tester.getRect(find
    .descendant(
      of: card,
      matching: find.byWidgetPredicate(
          (w) => w is DecoratedBox && w.decoration is ShapeDecoration),
    )
    .first);

void main() {
  setUp(() {
    setPinPrefs();
    demoRuntime.value = true;
  });
  tearDown(() => demoRuntime.value = false);

  testWidgets('landscape: cards, history and PIN tools clear the cutout',
      (tester) async {
    _landscape(tester);
    await _pump(tester);
    const width = 874.0;

    // The Vault picker spans exactly the cards' width, above the first card.
    final picker = _picker(tester, 'tab_pending', 'tab_history');
    expect(picker.left, 62 + 20, reason: 'island inset + card gutter');
    expect(picker.right, width - 62 - 20);
    final card = _surface(tester, find.byType(AuthRequestCard).first);
    expect(card.left, 62 + 20, reason: 'island inset + card gutter');
    expect(card.right, width - 62 - 20);
    expect(card.top - picker.bottom, 14, reason: 'as under the PIN picker');

    await _tab(tester, 'tab_history');
    expect(_picker(tester, 'tab_pending', 'tab_history'), picker);
    final entry = _surface(tester, find.byType(ContentCard).first);
    expect(entry.left, 62 + 20);
    expect(entry.right, width - 62 - 20);
    expect(entry.top - picker.bottom, 14);

    await _tab(tester, 'tab_pin');
    // The tool picker is the same control at the same spot as Vault's.
    final tools = _picker(tester, 'pin_tool_shift', 'pin_tool_yubikey');
    expect(tools, rectMoreOrLessEquals(picker));
    final pinCard = _surface(tester, find.byType(PinCard).first);
    expect(pinCard.left, greaterThanOrEqualTo(62 + 20));
    expect(pinCard.right, lessThanOrEqualTo(width - 62 - 20));

    await tester.pumpWidget(const SizedBox());
  });

  for (final (name, setSize) in [
    ('landscape', _landscape),
    ('portrait', _portrait),
  ]) {
    testWidgets('$name: at the list end the demo FAB clears the last card',
        (tester) async {
      setSize(tester);
      await _pump(tester);
      // More than a screenful of cards.
      for (var i = 0; i < 3; i++) {
        await tester.tap(byId('btn_add_demo'));
        await tester.pump(const Duration(milliseconds: 300));
      }
      await _scrollToEnd(tester);

      final fab = tester.getRect(find.byType(FloatingActionButton));
      final lastApprove = tester.getRect(find
          .descendant(
            of: find.byType(AuthRequestCard).last,
            matching: find.byType(FilledButton),
          )
          .first);
      final lastCard = tester.getRect(find.byType(AuthRequestCard).last);
      expect(lastApprove.bottom, lessThan(fab.top));
      expect(lastCard.bottom, lessThanOrEqualTo(fab.top - 8),
          reason: 'the whole card, frame included, sits above the FAB');
      await tester.pumpWidget(const SizedBox());
    });
  }
}
