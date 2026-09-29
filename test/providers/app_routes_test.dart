import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/app.dart';
import 'package:vault_approver/providers/session_provider.dart';
import 'package:vault_approver/screens/requests_screen.dart';
import 'package:vault_approver/screens/setup_screen.dart';
import 'package:vault_approver/utils/external_picker.dart';

import 'provider_fakes.dart';

Future<Harness> _signedInApp(WidgetTester tester) async {
  final h = await Harness.create();
  await h.signIn();
  await tester.pumpWidget(UncontrolledProviderScope(
    container: h.container,
    child: const App(),
  ));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  expect(find.byType(RequestsScreen), findsOneWidget);
  expect(h.container.read(isLockedProvider), isFalse);
  return h;
}

Future<void> _tearDown(WidgetTester tester, Harness h) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  h.dispose();
}

void _background(WidgetTester tester) {
  for (final s in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
  }
}

void _foreground(WidgetTester tester) {
  for (final s in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
  }
}

void main() {
  setUp(() => externalPickerDepth.value = 0);

  testWidgets('a system file picker does not lock the app (Android)',
      (tester) async {
    final h = await _signedInApp(tester);
    final picked = Completer<String?>();
    final pick = runExternalPicker(() => picked.future);
    expect(externalPickerActive, isTrue);

    _background(tester);
    await tester.pump();
    expect(h.container.read(isLockedProvider), isFalse);
    _foreground(tester);
    await tester.pump();
    expect(h.container.read(isLockedProvider), isFalse);
    expect(h.container.read(userKeyProvider), isNotNull);

    picked.complete('cert.p12');
    expect(await pick, 'cert.p12');
    expect(externalPickerActive, isFalse);

    // Without a picker, leaving the app still locks it.
    _background(tester);
    await tester.pump();
    expect(h.container.read(isLockedProvider), isTrue);
    _foreground(tester);
    await _tearDown(tester, h);
  });

  testWidgets(
      'session ended by the server closes the Settings sheet; the notice '
      'is visible', (tester) async {
    final h = await _signedInApp(tester);
    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.byType(DraggableScrollableSheet), findsOneWidget);

    h.api.simulateSessionEnded();
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(SetupScreen), findsOneWidget);
    expect(find.byType(DraggableScrollableSheet), findsNothing);
    final notice = find.descendant(
      of: find.byType(SnackBar),
      matching:
          find.text('Your session ended on the server. Please log in again.'),
    );
    expect(notice, findsOneWidget);
    // Nothing covers it: a hit test at its centre reaches the text.
    final text = tester.renderObject(notice);
    final hit = tester.hitTestOnBinding(tester.getCenter(notice));
    expect(hit.path.any((e) => identical(e.target, text)), isTrue);
    await tester.pump(const Duration(seconds: 9));
    await _tearDown(tester, h);
  });
}
