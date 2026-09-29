import 'package:flutter/material.dart';
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

Future<void> _pump(WidgetTester tester, VoidCallback onUnder) async {
  tester.view.physicalSize = const Size(1206, 2622);
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: _Host(onUnder: onUnder)));
  await tester.pump();
}

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

  testWidgets(
      'the tab droplet renders with the bar glass: no ignored per-widget '
      'settings (and no log line per animation frame)', (tester) async {
    final logged = <String>[];
    final saved = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) logged.add(message);
    };
    try {
      await _pump(tester, () {});
      await tester.tap(find.text('Three'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('One'));
      await tester.pumpAndSettle();
    } finally {
      debugPrint = saved;
    }

    expect(
      logged.where((m) => m.contains('without `useOwnLayer: true`')),
      isEmpty,
    );
    final droplet = tester.widget<GlassContainer>(find.descendant(
      of: find.byType(GlassTopBar),
      matching: find.byWidgetPredicate(
          (w) => w is GlassContainer && w.shape is LiquidRoundedSuperellipse),
    ));
    expect(droplet.settings, isNull);
    expect(droplet.useOwnLayer, isFalse);
  });
}
