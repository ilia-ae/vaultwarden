// Android polish from the emulator run (plan block E → D2): the seed
// placeholder fits a 360 pt phone, the "PIV PIN is part of field …" warning
// comes once, Android 13+ gets no second "Copied" message, and the threat
// models say that hidden fields flash the last typed character.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/l10n/app_localizations.dart';
import 'package:vault_approver/pin_tools/yubikey_secrets.dart' show ykFields;
import 'package:vault_approver/screens/pin/pin_widgets.dart';
import 'package:vault_approver/services/privacy_service.dart';

import 'pin_harness.dart';

Future<void> _tap(WidgetTester tester, String id) async {
  await tester.ensureVisible(byId(id));
  await tester.pump();
  await tester.tap(byId(id));
  await tester.pump();
}

Future<void> _expand(WidgetTester tester, String id) async {
  await _tap(tester, id);
  await tester.pumpAndSettle();
}

/// Ledger mode on the seed PIN 24 cached (abandon×11 about), one serial.
Future<void> _ledgerKey(WidgetTester tester, String serial) async {
  await enterPin24(tester, seed: abandon12, nickname: 'yk-$serial-pins');
  await _tap(tester, 'pin_tool_yubikey');
  await tester.enterText(fieldById('yk_serials'), serial);
  await settleDerivation(tester);
}

Finder _snack(String text) =>
    find.descendant(of: find.byType(SnackBar), matching: find.text(text));

void main() {
  setUp(setPinPrefs);

  group('seed placeholder', () {
    // The test font draws every glyph 1 em wide, which says nothing about a
    // phone: measure with Android's Roboto from the Flutter SDK instead.
    setUpAll(() async {
      final root = Platform.environment['FLUTTER_ROOT'] ??
          File(Platform.resolvedExecutable)
              .parent // darwin-x64 (or linux-x64 …)
              .parent // engine
              .parent // artifacts
              .parent // cache
              .parent // bin
              .parent
              .path;
      final font =
          File('$root/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf');
      if (!font.existsSync()) fail('Roboto not found: ${font.path}');
      final loader = FontLoader('Roboto')
        ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
      await loader.load();
    });

    for (final locale in const [Locale('en'), Locale('ar')]) {
      testWidgets('fits one line at 360 pt without an ellipsis ($locale)',
          (tester) async {
        tester.view.physicalSize = const Size(360, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        mockPrivacyChannel(tester);
        await pumpPin(tester, locale: locale);
        expect(
            DefaultTextStyle.of(tester.element(byId('pin24_seed')))
                .style
                .fontFamily,
            anyOf('Roboto', isNull));

        final field = find.descendant(
            of: byId('pin24_seed'), matching: find.byType(TextField));
        final hint = tester.widget<TextField>(field).decoration!.hintText!;
        expect(hint, isNot(contains('…')));
        final paragraph = tester.renderObject<RenderParagraph>(
            find.descendant(of: byId('pin24_seed'), matching: find.text(hint)));
        expect(paragraph.didExceedMaxLines, isFalse,
            reason: 'the hint is cut off ("…") at 360 pt');
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('"PIV PIN is part of field …" is one warning listing the fields',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    final l = l10n(tester);
    await _ledgerKey(tester, '38715242');

    final notices = find.descendant(
        of: byId('yk_warning_38715242_00'), matching: find.byType(PinNotice));
    expect(notices, findsOneWidget);
    final fields = ['23', '24', '34'];
    expect(
      tester.widget<PinNotice>(notices).text,
      l.pinYkWarnPivInFields(
        3,
        ltrIsolate(
            [for (final f in fields) '$f (${ykFields[f]!.name})'].join(', ')),
      ),
    );
    // The other fields' own warnings are unchanged (Admin PIN shares -pins).
    expect(find.text(l.pinYkWarnAdminShares), findsOneWidget);
  });

  test('one-field and many-field wording', () {
    final en = lookupAppLocalizations(const Locale('en'));
    final ru = lookupAppLocalizations(const Locale('ru'));
    expect(en.pinYkWarnPivInFields(1, '23 (x)'), contains('part of field 23'));
    expect(en.pinYkWarnPivInFields(3, 'a, b, c'), contains('fields a, b, c'));
    expect(ru.pinYkWarnPivInFields(1, '23'), contains('часть поля 23'));
    expect(ru.pinYkWarnPivInFields(3, '23'), contains('часть полей 23'));
  });

  group('copy confirmation (Android 13+ shows its own)', () {
    for (final systemConfirms in [false, true]) {
      testWidgets(
          'YubiKey value and PIN 24 full password, system confirms: '
          '$systemConfirms', (tester) async {
        useTallSurface(tester);
        final channel = mockPrivacyChannel(tester,
            systemShowsCopyConfirmation: systemConfirms);
        await pumpPin(tester);
        final l = l10n(tester);

        await enterPin24(tester, seed: abandon12, nickname: 'visa');
        await _tap(tester, 'pin24_show_full');
        await _tap(tester, 'pin24_copy_full');
        await tester.pump();
        expect(channel.named('copySensitive'), hasLength(1));
        expect(
            _snack(l.pinCopiedTtl), systemConfirms ? findsNothing : findsOne);

        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        await _ledgerKey(tester, '38715242');
        await _tap(tester, 'yk_copy_38715242_45');
        await tester.pump();
        expect(channel.named('copySensitive'), hasLength(2));
        expect(
            _snack(l.pinCopiedTtl), systemConfirms ? findsNothing : findsOne);
      });
    }

    testWidgets('a failed copy is always reported', (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester, systemShowsCopyConfirmation: true);
      // The native copy fails (Android: no plain-clipboard fallback).
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel(PrivacyService.channelName),
        (call) async => switch (call.method) {
          'copySensitive' => throw PlatformException(code: 'privacy_failed'),
          'isScreenCaptured' => false,
          'systemShowsCopyConfirmation' => true,
          _ => true,
        },
      );
      await pumpPin(tester);
      final l = l10n(tester);
      await enterPin24(tester, seed: abandon12, nickname: 'visa');
      await _tap(tester, 'pin24_show_full');
      await _tap(tester, 'pin24_copy_full');
      await tester.pump();
      expect(_snack(l.pinCopyFailed), findsOneWidget);
    });
  });

  testWidgets('threat models mention the briefly shown last character',
      (tester) async {
    useTallSurface(tester);
    mockPrivacyChannel(tester);
    await pumpPin(tester);
    final l = l10n(tester);
    final note = find.textContaining(l.pinHiddenLastCharNote);

    await _expand(tester, 'pin24_threat_model');
    expect(note, findsOneWidget);

    await _tap(tester, 'pin_tool_shift');
    await tester.pumpAndSettle();
    await _expand(tester, 'pin_shift_threat');
    expect(note, findsOneWidget);

    await _tap(tester, 'pin_tool_yubikey');
    await tester.pumpAndSettle();
    await _expand(tester, 'yk_notes');
    expect(note, findsOneWidget);
  });
}
