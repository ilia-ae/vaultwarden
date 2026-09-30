import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/models/server_environment.dart';
import 'package:vault_approver/widgets/option_pills.dart';
import 'package:vault_approver/widgets/segmented_tabs.dart';
import 'package:vault_approver/widgets/server_selector.dart';

Widget _host(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      // The app's own theme: seeded blue, so an accent would show up here.
      theme: ThemeData(colorSchemeSeed: Colors.blue, brightness: brightness),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Center(child: child)),
    );

/// The stadium behind [label] and the label's own style.
(ShapeDecoration, TextStyle?) _look(WidgetTester tester, String label) {
  final box = tester.widget<Container>(find
      .ancestor(of: find.text(label), matching: find.byType(Container))
      .first);
  final text = tester.widget<Text>(find.text(label));
  return (box.decoration! as ShapeDecoration, text.style);
}

StadiumBorder _stadium(ShapeDecoration d) => d.shape as StadiumBorder;

void main() {
  testWidgets('OptionPills: one selected, tap fires even on the selected one',
      (tester) async {
    final taps = <int>[];
    await tester.pumpWidget(_host(OptionPills<int>(
      options: const [(value: 4, label: 'Four'), (value: 6, label: 'Six')],
      identifiers: const ['len_4', 'len_6'],
      selected: 4,
      onSelected: taps.add,
    )));

    final handle = tester.ensureSemantics();
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('len_4')),
      matchesSemantics(
        identifier: 'len_4',
        label: 'Four',
        isButton: true,
        hasTapAction: true,
        isSelected: true,
        hasSelectedState: true,
      ),
    );
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('len_6')),
      matchesSemantics(
        identifier: 'len_6',
        label: 'Six',
        isButton: true,
        hasTapAction: true,
        hasSelectedState: true,
      ),
    );
    handle.dispose();

    await tester.tap(find.text('Six'));
    await tester.tap(find.text('Four'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(taps, [6, 4]);
  });

  testWidgets('MultiOptionPills toggles independently', (tester) async {
    final selected = <String>{'a'};
    await tester.pumpWidget(StatefulBuilder(
      builder: (context, setState) => _host(MultiOptionPills<String>(
        options: const [(value: 'a', label: 'A'), (value: 'b', label: 'B')],
        selected: selected,
        onToggled: (v) => setState(() {
          if (!selected.remove(v)) selected.add(v);
        }),
      )),
    ));
    await tester.tap(find.text('B'));
    await tester.pump();
    await tester.tap(find.text('A'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(selected, {'b'});
  });

  testWidgets('SectionHeader uses labelLarge in onSurfaceVariant',
      (tester) async {
    await tester.pumpWidget(_host(const SectionHeader('Theme')));
    final text = tester.widget<Text>(find.text('Theme'));
    final theme = Theme.of(tester.element(find.text('Theme')));
    expect(text.style?.color, theme.colorScheme.onSurfaceVariant);
    expect(text.style?.fontSize, theme.textTheme.labelLarge?.fontSize);
  });

  // Accent rule: blue only for the active top-tab underline and Approve. A
  // selected pill is neutral — the SegmentedTabs greys — and keeps its
  // selected semantics (checked in the first test).
  for (final brightness in Brightness.values) {
    testWidgets('selected pill is neutral, not the accent ($brightness)',
        (tester) async {
      await tester.pumpWidget(_host(
        OptionPills<int>(
          options: const [(value: 4, label: 'Four'), (value: 6, label: 'Six')],
          selected: 4,
          onSelected: (_) {},
        ),
        brightness: brightness,
      ));
      final cs = Theme.of(tester.element(find.text('Four'))).colorScheme;

      final (on, onStyle) = _look(tester, 'Four');
      expect(on.color, OptionPill.selectedFill(brightness));
      expect(on.color, isNot(cs.primaryContainer));
      expect(on.color, isNot(cs.primary));
      expect(
        on.color,
        brightness == Brightness.dark
            ? SegmentedTabs.thumbColor(brightness)
            : SegmentedTabs.trackColor(brightness),
      );
      expect(_stadium(on).side, BorderSide.none);
      expect(onStyle?.color, cs.onSurface);
      expect(onStyle?.fontWeight, FontWeight.w600);

      final (off, offStyle) = _look(tester, 'Six');
      expect(off.color, Colors.transparent);
      expect(
          _stadium(off).side.color, cs.outlineVariant.withValues(alpha: 0.6));
      expect(offStyle?.color, cs.onSurfaceVariant);
      expect(offStyle?.fontWeight, FontWeight.w500);
    });

    testWidgets('setup server pills share the neutral look ($brightness)',
        (tester) async {
      await tester.pumpWidget(_host(
        SizedBox(
          width: 360,
          child: ServerSelector(region: ServerRegion.eu, onChanged: (_) {}),
        ),
        brightness: brightness,
      ));
      final cs =
          Theme.of(tester.element(find.text('bitwarden.eu'))).colorScheme;

      final (on, onStyle) = _look(tester, 'bitwarden.eu');
      expect(on.color, OptionPill.selectedFill(brightness));
      expect(on.color, isNot(cs.primaryContainer));
      expect(onStyle?.color, cs.onSurface);

      final (off, offStyle) = _look(tester, 'bitwarden.com');
      expect(off.color, Colors.transparent);
      expect(offStyle?.color, cs.onSurfaceVariant);
    });
  }
}
