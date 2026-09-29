import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/app.dart';
import 'package:vault_approver/demo_fixtures.dart';
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/providers/auth_requests_provider.dart';
import 'package:vault_approver/providers/session_provider.dart';
import 'package:vault_approver/screens/requests_screen.dart';
import 'package:vault_approver/screens/setup_screen.dart';

import 'provider_fakes.dart';

void main() {
  tearDown(() => demoRuntime.value = false);

  testWidgets('runtime demo runs in its own container and leaves no trace',
      (tester) async {
    final h = await Harness.create();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: h.container,
      child: const App(),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(SetupScreen), findsOneWidget);
    final before = await h.keychain();

    h.container.read(sessionProvider.notifier).enterRuntimeDemo();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(RequestsScreen), findsOneWidget);
    expect(find.text('Demo mode — sample data, not a real account'),
        findsOneWidget);
    // R9: the ribbon and the window title come from the ARB files.
    final en = lookupAppLocalizations(const Locale('en'));
    expect(tester.widget<Banner>(find.byType(Banner)).message, en.demoRibbon);
    expect(tester.widget<Title>(find.byType(Title).first).title, en.appTitle);
    // The real container never saw the demo.
    expect(h.container.read(sessionProvider).value, isNull);
    expect(h.container.read(historyProvider), isEmpty);

    // Log out of the demo from inside it.
    final demoElement = tester.element(find.byType(RequestsScreen));
    await ProviderScope.containerOf(demoElement)
        .read(sessionProvider.notifier)
        .logout();
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(find.byType(SetupScreen), findsOneWidget);
    expect(demoRuntime.value, isFalse);
    expect(h.api.serverCalls, isEmpty);
    expect(h.hub.connects, isEmpty);
    expect(await h.keychain(), before);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    h.dispose();
  });

  testWidgets('a keychain read error shows the retry screen (R4)',
      (tester) async {
    final h = await Harness.create(storage: ThrowingSessionStorage());
    await tester.pumpWidget(UncontrolledProviderScope(
      container: h.container,
      child: const App(),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(StorageErrorScreen), findsOneWidget);
    expect(find.byType(SetupScreen), findsNothing);
    await tester.pumpWidget(const SizedBox());
    h.dispose();
  });
}
