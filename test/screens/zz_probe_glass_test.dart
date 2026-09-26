import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/widgets/glass_top_bar.dart';

void main() {
  testWidgets('probe glass', (tester) async {
    final c = TabController(length: 3, vsync: const TestVSync());
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: GlassTopBar(title: 'T', controller: c, tabs: const ['a', 'b', 'c']),
        body: const SizedBox(),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('c'), findsOneWidget);
  });
}
