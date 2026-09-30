import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsRole;
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:vault_approver/widgets/glass_top_bar.dart';

/// A screen like RequestsScreen: the list scrolls under the glass bar.
class _Host extends StatefulWidget {
  const _Host({required this.onUnder});

  final VoidCallback onUnder;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with TickerProviderStateMixin {
  late final TabController controller = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: GlassTopBar(
        title: 'Title',
        controller: controller,
        tabs: const ['One', 'Two', 'Three'],
        tabIdentifiers: const ['tab_one', 'tab_two', 'tab_three'],
      ),
      // No top padding: the first row sits right under the bar, the way a
      // card does once it has been scrolled up.
      body: ListView(
        padding: EdgeInsets.zero,
        children: [
          SizedBox(
            height: 400,
            child: Material(
              child: InkWell(onTap: widget.onUnder, child: const SizedBox()),
            ),
          ),
          const SizedBox(height: 2000),
        ],
      ),
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  VoidCallback onUnder, {
  TextDirection direction = TextDirection.ltr,
  bool reduceMotion = false,
  Brightness brightness = Brightness.dark,
  double textScale = 1,
}) async {
  tester.view.physicalSize = const Size(1206, 2622);
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(colorSchemeSeed: Colors.blue, brightness: brightness),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          disableAnimations: reduceMotion,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Directionality(
          textDirection: direction,
          child: _Host(onUnder: onUnder),
        ),
      ),
    ),
  ));
  await tester.pump();
}

Finder _underline() => find.byKey(GlassTopBar.underlineKey);

TabController _controller(WidgetTester tester) =>
    tester.widget<GlassTopBar>(find.byType(GlassTopBar)).controller;

/// The painted label of a tab.
Rect _label(WidgetTester tester, String text) =>
    tester.getRect(find.text(text));

/// Where the label's alphabetic baseline is drawn (after any scale-down).
double _baseline(WidgetTester tester, String text) {
  final rich = tester.widget<RichText>(
      find.descendant(of: find.text(text), matching: find.byType(RichText)));
  final painter = TextPainter(
    text: rich.text,
    textDirection: TextDirection.ltr,
    textScaler: rich.textScaler,
  )..layout();
  final baseline =
      painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
  final height = painter.height;
  painter.dispose();
  final box = _label(tester, text);
  return box.top + baseline * box.height / height;
}

Color _labelColor(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!.color!;

void main() {
  testWidgets(
      'empty parts of the bar take the tap: nothing scrolled under it is hit',
      (tester) async {
    var taps = 0;
    await _pump(tester, () => taps++);
    final bar = tester.getRect(find.byType(GlassTopBar));
    expect(bar.bottom, greaterThan(150));

    for (final point in [
      const Offset(20, 30), // status-bar strip
      const Offset(20, 90), // beside the title
      Offset(8, bar.bottom - 4), // the tab row's margin
    ]) {
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 500));
      expect(taps, 0, reason: 'tap at $point went through the bar');
    }
    // A drag on the bar does not scroll the list under it either.
    await tester.dragFrom(const Offset(20, 90), const Offset(0, -200));
    await tester.pump();
    expect(tester.getTopLeft(find.byType(InkWell)).dy, 0);

    // Below the bar the same row still takes its taps.
    await tester.tapAt(Offset(200, bar.bottom + 40));
    await tester.pump(const Duration(milliseconds: 500));
    expect(taps, 1);
  });

  testWidgets('plain text tabs: no droplet or frame, an underline instead',
      (tester) async {
    await _pump(tester, () {});
    // The bar's own glass is the only glass: nothing around the labels.
    expect(
      find.descendant(
          of: find.byType(GlassTopBar), matching: find.byType(GlassContainer)),
      findsOneWidget,
    );
    final bar = tester.getRect(find.byType(GlassTopBar));
    for (final shape in [LiquidRoundedSuperellipse, LiquidRoundedRectangle]) {
      final framed = find.descendant(
        of: find.byType(GlassTopBar),
        matching: find.byWidgetPredicate(
            (w) => w is GlassContainer && w.shape.runtimeType == shape),
      );
      for (final e in framed.evaluate()) {
        expect(tester.getRect(find.byWidget(e.widget)), bar,
            reason: 'only the bar itself');
      }
    }
    // Every decorated box in the tab row is the underline.
    final decorated = find.descendant(
      of: find.byType(GlassTopBar),
      matching: find.byWidgetPredicate(
          (w) => w is DecoratedBox && w.decoration is ShapeDecoration),
    );
    expect(decorated, findsOneWidget);

    // A short accent line under the active label, as wide as the label.
    final cs = Theme.of(tester.element(find.byType(GlassTopBar))).colorScheme;
    final line = tester.getRect(_underline());
    final one = _label(tester, 'One');
    final box = tester.widget<DecoratedBox>(
        find.descendant(of: _underline(), matching: find.byType(DecoratedBox)));
    expect((box.decoration as ShapeDecoration).color, cs.primary);
    expect(line.height, 3);
    expect(line.center.dx, moreOrLessEquals(one.center.dx));
    expect(line.width, moreOrLessEquals(one.width));
    expect(line.top, greaterThan(one.bottom), reason: 'under the label');
    // Close under it: a few points below the baseline.
    expect(line.top - _baseline(tester, 'One'), inInclusiveRange(4, 14));
    expect(line.bottom, lessThanOrEqualTo(bar.bottom));
    // The active label bright, the others muted.
    expect(_labelColor(tester, 'One'), cs.onSurface);
    for (final other in ['Two', 'Three']) {
      final c = _labelColor(tester, other);
      expect(c.a, lessThan(cs.onSurface.a));
      expect(c.withValues(alpha: 1), cs.onSurface.withValues(alpha: 1));
    }
  });

  testWidgets('the underline glides to the tapped tab with the spring',
      (tester) async {
    await _pump(tester, () {});
    final one = _label(tester, 'One');
    final three = _label(tester, 'Three');
    await tester.tap(find.text('Three'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    // On its way: between the two labels.
    final mid = tester.getRect(_underline());
    expect(mid.center.dx, inExclusiveRange(one.center.dx, three.center.dx));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    final line = tester.getRect(_underline());
    expect(line.center.dx, moreOrLessEquals(three.center.dx));
    expect(line.width, moreOrLessEquals(three.width));
    expect(_controller(tester).index, 2);
    final cs = Theme.of(tester.element(find.byType(GlassTopBar))).colorScheme;
    expect(_labelColor(tester, 'Three'), cs.onSurface);
    expect(_labelColor(tester, 'One').a, lessThan(1));
  });

  testWidgets('the underline follows a drag of the controller (swipes)',
      (tester) async {
    await _pump(tester, () {});
    final one = _label(tester, 'One');
    final two = _label(tester, 'Two');
    // A page swipe moves TabController.offset without an index change.
    _controller(tester).offset = 0.5;
    await tester.pump();
    expect(tester.getRect(_underline()).center.dx,
        moreOrLessEquals((one.center.dx + two.center.dx) / 2));
  });

  testWidgets('Reduce Motion: the underline jumps', (tester) async {
    await _pump(tester, () {}, reduceMotion: true);
    await tester.tap(find.text('Two'));
    await tester.pump();
    expect(tester.getRect(_underline()).center.dx,
        moreOrLessEquals(_label(tester, 'Two').center.dx));
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('RTL: the first tab and its underline are on the right',
      (tester) async {
    await _pump(tester, () {}, direction: TextDirection.rtl);
    final one = _label(tester, 'One');
    expect(one.center.dx, greaterThan(402 / 2));
    expect(tester.getRect(_underline()).center.dx,
        moreOrLessEquals(one.center.dx));
    await tester.tap(find.text('Three'));
    await tester.pumpAndSettle();
    final three = _label(tester, 'Three');
    expect(three.center.dx, lessThan(402 / 2));
    expect(tester.getRect(_underline()).center.dx,
        moreOrLessEquals(three.center.dx));
  });

  testWidgets('tabs: 48-pt tap targets, tab semantics with selected state',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, () {});
    for (final id in ['tab_one', 'tab_two', 'tab_three']) {
      final rect = tester.getRect(find.bySemanticsIdentifier(id));
      expect(rect.height, greaterThanOrEqualTo(48), reason: id);
      expect(rect.width, greaterThanOrEqualTo(48), reason: id);
    }
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('tab_one')),
      matchesSemantics(
        identifier: 'tab_one',
        label: 'One',
        isButton: true,
        hasTapAction: true,
        isSelected: true,
        hasSelectedState: true,
      ),
    );
    final two = tester.getSemantics(find.bySemanticsIdentifier('tab_two'));
    expect(two.getSemanticsData().role, SemanticsRole.tab);
    expect(two.parent!.getSemanticsData().role, SemanticsRole.tabBar);
    expect(two.flagsCollection.isSelected, Tristate.isFalse);

    await tester.tap(find.bySemanticsIdentifier('tab_two'));
    await tester.pumpAndSettle();
    expect(
        tester
            .getSemantics(find.bySemanticsIdentifier('tab_two'))
            .flagsCollection
            .isSelected,
        Tristate.isTrue);
    handle.dispose();
  });

  testWidgets('text scale 2: labels fit the bar, the underline under them',
      (tester) async {
    await _pump(tester, () {}, textScale: 2);
    expect(tester.takeException(), isNull);
    final bar = tester.getRect(find.byType(GlassTopBar));
    final one = _label(tester, 'One');
    final line = tester.getRect(_underline());
    expect(line.top, greaterThan(_baseline(tester, 'One')),
        reason: 'under the label');
    expect(line.bottom, lessThanOrEqualTo(bar.bottom));
    expect(line.center.dx, moreOrLessEquals(one.center.dx));
  });
}
