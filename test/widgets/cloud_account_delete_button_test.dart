import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/services/auth_service.dart';
import 'package:vault_approver/services/settings_sync.dart';
import 'package:vault_approver/utils/external_picker.dart';
import 'package:vault_approver/widgets/cloud_account_delete_button.dart';

import '../screens/screen_harness.dart';

class _FakeCoordinator extends Fake implements SettingsSyncCoordinator {
  int calls = 0;
  bool pickerGuardSeen = false;
  Completer<void>? gate;
  Object? error;

  @override
  Future<void> deleteAccount() async {
    calls++;
    pickerGuardSeen = externalPickerActive;
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
  }

  @override
  void dispose() {}
}

Future<_FakeCoordinator> _pump(WidgetTester tester) async {
  final coordinator = _FakeCoordinator();
  final container = ProviderContainer(overrides: [
    settingsSyncCoordinatorProvider.overrideWithValue(coordinator),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(testApp(
    container,
    const Scaffold(body: Center(child: CloudAccountDeleteButton())),
  ));
  return coordinator;
}

Future<void> _openConfirm(WidgetTester tester) async {
  await tester.tap(find.byType(CloudAccountDeleteButton));
  await tester.pumpAndSettle();
  expect(find.text(en().cloudSyncDeleteTitle), findsOneWidget);
  expect(find.text(en().cloudSyncDeleteBody), findsOneWidget);
}

Future<void> _confirm(WidgetTester tester) async {
  await tester.tap(find.descendant(
    of: find.byType(AlertDialog),
    matching: find.text(en().cloudSyncDeleteAccount),
  ));
  await tester.pump();
}

void main() {
  testWidgets('cancel in the confirmation deletes nothing', (tester) async {
    final coordinator = await _pump(tester);
    await _openConfirm(tester);
    await tester.tap(find.text(en().cancel));
    await tester.pumpAndSettle();
    expect(coordinator.calls, 0);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('confirmed: busy while running, then "Account deleted"',
      (tester) async {
    final coordinator = await _pump(tester)
      ..gate = Completer<void>();
    await _openConfirm(tester);
    await _confirm(tester);
    await tester.pump();
    expect(coordinator.calls, 1);
    expect(coordinator.pickerGuardSeen, isTrue,
        reason: 'auto-lock must not close the sheet under the Apple/Google UI');
    expect(find.text(en().cloudSyncDeleting), findsOneWidget);
    final button = tester.widget<TextButton>(find.descendant(
        of: find.byType(CloudAccountDeleteButton),
        matching: find.byWidgetPredicate((w) => w is TextButton)));
    expect(button.onPressed, isNull);

    coordinator.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text(en().cloudSyncDeleteDoneTitle), findsOneWidget);
    expect(externalPickerActive, isFalse);
  });

  testWidgets('cancelled confirming sign-in: no dialog', (tester) async {
    final coordinator = await _pump(tester)
      ..error = AuthException(AuthFailure.cancelled, provider: 'Apple');
    await _openConfirm(tester);
    await _confirm(tester);
    await tester.pumpAndSettle();
    expect(coordinator.calls, 1);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(en().cloudSyncDeleteAccount), findsOneWidget);
  });

  testWidgets('another account picked: explained', (tester) async {
    (await _pump(tester)).error =
        AuthException(AuthFailure.wrongAccount, provider: 'Apple');
    await _openConfirm(tester);
    await _confirm(tester);
    await tester.pumpAndSettle();
    expect(find.text(en().cloudSyncDeleteFailedTitle), findsOneWidget);
    expect(find.text(en().cloudSyncErrorWrongAccount('Apple')), findsOneWidget);
  });

  testWidgets('offline: timeout message', (tester) async {
    (await _pump(tester)).error = TimeoutException('offline');
    await _openConfirm(tester);
    await _confirm(tester);
    await tester.pumpAndSettle();
    expect(find.text(en().cloudSyncDeleteErrorTimeout), findsOneWidget);
  });

  testWidgets('deletion refused: code shown', (tester) async {
    (await _pump(tester)).error = AuthException(AuthFailure.deleteFailed,
        provider: 'Apple', detail: 'permission-denied');
    await _openConfirm(tester);
    await _confirm(tester);
    await tester.pumpAndSettle();
    expect(find.text(en().cloudSyncDeleteErrorFailed('permission-denied')),
        findsOneWidget);
  });
}
