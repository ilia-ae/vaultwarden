import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/demo_runtime.dart';
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';
import 'package:vault_approver/screens/requests_screen.dart';

import 'pin/pin_harness.dart';

/// The `enabled` argument of every `setSecureScreen` call so far.
List<Object?> secureCalls(PrivacyChannelLog log) => [
      for (final c in log.named('setSecureScreen'))
        (c.arguments as Map)['enabled'],
    ];

Future<void> tapTab(WidgetTester tester, String id) async {
  await tester.tap(byId(id));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 700));
  // A page first built in the last animation frame loads its prefs after it.
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() {
    setPinPrefs();
    // Demo data: no network, no biometrics, fixture requests and history.
    demoRuntime.value = true;
  });
  tearDown(() => demoRuntime.value = false);

  testWidgets('3rd tab: title, refresh, demo FAB and FLAG_SECURE by tab',
      (tester) async {
    useTallSurface(tester);
    final channel = mockPrivacyChannel(tester);
    await tester.pumpWidget(ProviderScope(
      overrides: [pinComputeRunnerProvider.overrideWithValue(inlineRunner)],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: RequestsScreen(),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    final l = AppLocalizations.of(tester.element(find.byType(RequestsScreen)))!;
    final container =
        ProviderScope.containerOf(tester.element(find.byType(RequestsScreen)));

    for (final id in ['tab_pending', 'tab_history', 'tab_pin']) {
      expect(byId(id), findsOneWidget, reason: id);
    }
    expect(find.text(l.pinTab), findsOneWidget);
    expect(find.text(l.authRequestsTitle), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(byId('btn_add_demo'), findsOneWidget);
    expect(secureCalls(channel), isEmpty);

    await tapTab(tester, 'tab_history');
    expect(byId('btn_add_demo'), findsNothing, reason: 'FAB only on tab 0');
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(secureCalls(channel), isEmpty);

    await tapTab(tester, 'tab_pin');
    expect(find.text(l.pinTitle), findsOneWidget);
    expect(find.text(l.authRequestsTitle), findsNothing);
    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(byId('btn_add_demo'), findsNothing);
    expect(byId('pin_tool_pin24'), findsOneWidget);
    expect(secureCalls(channel), [true]);
    expect(container.exists(pinSessionProvider), isTrue);

    await tapTab(tester, 'tab_pending');
    expect(find.text(l.authRequestsTitle), findsOneWidget);
    expect(byId('btn_add_demo'), findsOneWidget);
    expect(secureCalls(channel), [true, false]);
    // Leaving the tab disposed the section's session (and its seed cache).
    expect(container.exists(pinSessionProvider), isFalse);

    // Unmounting while on the PIN tab releases FLAG_SECURE.
    await tapTab(tester, 'tab_pin');
    expect(secureCalls(channel), [true, false, true]);
    await tester.pumpWidget(const SizedBox());
    expect(secureCalls(channel), [true, false, true, false]);
  });
}
