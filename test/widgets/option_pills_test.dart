import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/widgets/option_pills.dart';

Widget _host(Widget child) =>
    MaterialApp(home: Scaffold(body: Center(child: child)));

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
}
