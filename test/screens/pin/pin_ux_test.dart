// UX regression tests from the C8 review of the PIN tab: flows between the
// tools, confirmations, dialogs, accessibility labels and small states.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/glass.dart';
import 'package:vault_approver/pin_tools/ledger_pin24.dart' show kCharsets;
import 'package:vault_approver/pin_tools/pin24_selftest.dart';
import 'package:vault_approver/pin_tools/yubikey_secrets.dart' show ykFields;
import 'package:vault_approver/screens/pin/pin24_selftest_hook.dart';
import 'package:vault_approver/screens/pin/pin_section.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';
import 'package:vault_approver/screens/pin/pin_widgets.dart';
import 'package:vault_approver/services/privacy_service.dart';

import 'pin_harness.dart';

const _masterA = 'SYNTHETIC-TEST-MASTER-KEY-A-0123456789abcdef';

Future<void> _tap(WidgetTester tester, String id) async {
  await tester.ensureVisible(byId(id));
  await tester.pump();
  await tester.tap(byId(id));
}

bool _pillSelected(WidgetTester tester, String id) =>
    tester.widget<Semantics>(byId(id)).properties.selected!;

String? _tooltip(WidgetTester tester, String id) => tester
    .widget<IconButton>(
        find.descendant(of: byId(id), matching: find.byType(IconButton)))
    .tooltip;

void main() {
  setUp(setPinPrefs);

  group('UX #4: YubiKey ↔ PIN 24', () {
    testWidgets('settings survive the trip; the seed works without a nickname',
        (tester) async {
      // A phone-sized viewport: the seed field must be scrolled into view.
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      mockPrivacyChannel(tester);
      final container = await pumpPin(tester);
      final l = l10n(tester);

      await _tap(tester, 'pin_tool_yubikey');
      await tester.pump();
      await tester.enterText(fieldById('yk_serials'), '38715242');
      await tester.pump();
      await _tap(tester, 'yk_phase_fido2'); // off
      await tester.pump();
      expect(_pillSelected(tester, 'yk_phase_fido2'), isFalse);
      expect(find.text(l.pinYkGateNoSeed), findsOneWidget);

      await _tap(tester, 'yk_go_pin24');
      await tester.pumpAndSettle();
      expect(byId('pin24_back_to_yk'), findsOneWidget);
      final seedRect = tester.getRect(byId('pin24_seed'));
      expect(seedRect.top, greaterThanOrEqualTo(0));
      expect(seedRect.bottom, lessThanOrEqualTo(844),
          reason: 'PIN 24 scrolled to its seed field');

      // Only the phrase: no nickname.
      await tester.enterText(fieldById('pin24_seed'), abandon12);
      await settleDerivation(tester);
      final cache = container.read(pinSeedProvider);
      expect(cache.hasSeed, isTrue, reason: 'cached as soon as it validated');
      expect(byId('pin24_seed_kept'), findsOneWidget);
      expect(byId('pin24_output'), findsNothing);

      await _tap(tester, 'pin24_back_to_yk');
      await tester.pump();
      await settleDerivation(tester);
      expect(byId('yk_view'), findsOneWidget);
      expect(fieldText(tester, 'yk_serials'), '38715242');
      expect(_pillSelected(tester, 'yk_phase_fido2'), isFalse);
      expect(find.text(l.pinYkUsingSeed(12)), findsOneWidget);
      expect(byId('yk_result_38715242'), findsOneWidget);
      expect(byId('yk_row_38715242_34'), findsNothing, reason: 'FIDO2 off');

      // Back on PIN 24 the field is empty, but the seed is still in memory.
      // (Fields 25/41 are random here, so leaving YubiKey asks first.)
      await _tap(tester, 'pin_tool_pin24');
      await tester.pumpAndSettle();
      await tester.tap(byId('pin_tool_switch_confirm'));
      await tester.pumpAndSettle();
      expect(fieldText(tester, 'pin24_seed'), isEmpty);
      expect(byId('pin24_back_to_yk'), findsNothing);
      expect(byId('pin24_seed_in_memory'), findsOneWidget);
      await _tap(tester, 'pin_wipe_cached_seed');
      await tester.pump();
      expect(cache.hasSeed, isFalse);
      expect(byId('pin24_seed_in_memory'), findsNothing);
    });

    testWidgets('a full wipe clears the serials kept for the YubiKey tool',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      final container = await pumpPin(tester);
      await _tap(tester, 'pin_tool_yubikey');
      await tester.pump();
      await tester.enterText(fieldById('yk_serials'), '38715242');
      await tester.pump();
      await _tap(tester, 'pin_tool_pin24');
      await tester.pump();
      container.read(pinSessionProvider).wipe(reason: PinWipeReason.inactivity);
      await tester.pump();
      await _tap(tester, 'pin_tool_yubikey');
      await tester.pump();
      expect(fieldText(tester, 'yk_serials'), isEmpty);
    });
  });

  group('UX #5: random values are not lost silently', () {
    Future<void> randomValues(WidgetTester tester) async {
      await _tap(tester, 'pin_tool_yubikey');
      await tester.pump();
      await _tap(tester, 'yk_source_random');
      await tester.pump();
      await tester.enterText(fieldById('yk_serials'), '12345678');
      await settleDerivation(tester);
      expect(byId('yk_random_warning'), findsOneWidget);
    }

    testWidgets('Clear asks first', (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester);
      final l = l10n(tester);
      await randomValues(tester);
      expect(l.pinYkRandomWarning, contains('tool'));

      await _tap(tester, 'yk_clear');
      await tester.pumpAndSettle();
      expect(find.text(l.pinYkRandomLoseTitle), findsOneWidget);
      await tester.tap(byId('yk_clear_cancel'));
      await tester.pumpAndSettle();
      expect(byId('yk_result_12345678'), findsOneWidget);

      await _tap(tester, 'yk_clear');
      await tester.pumpAndSettle();
      await tester.tap(byId('yk_clear_confirm'));
      await tester.pumpAndSettle();
      expect(byId('yk_result_12345678'), findsNothing);
      expect(fieldText(tester, 'yk_serials'), isEmpty);
    });

    testWidgets('switching tool asks first; without random values it does not',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester);
      await randomValues(tester);

      await _tap(tester, 'pin_tool_shift');
      await tester.pumpAndSettle();
      expect(byId('pin_tool_switch_confirm'), findsOneWidget);
      await tester.tap(byId('pin_tool_switch_cancel'));
      await tester.pumpAndSettle();
      expect(byId('yk_view'), findsOneWidget);
      expect(byId('yk_result_12345678'), findsOneWidget);

      await _tap(tester, 'pin_tool_shift');
      await tester.pumpAndSettle();
      await tester.tap(byId('pin_tool_switch_confirm'));
      await tester.pumpAndSettle();
      expect(byId('pin_shift_view'), findsOneWidget);

      // Master-key values can be recomputed: no question.
      await _tap(tester, 'pin_tool_yubikey');
      await tester.pump();
      await _tap(tester, 'yk_source_master');
      await tester.pump();
      await tester.enterText(fieldById('yk_master_key'), _masterA);
      await settleDerivation(tester);
      await _tap(tester, 'pin_tool_shift');
      await tester.pumpAndSettle();
      expect(byId('pin_tool_switch_confirm'), findsNothing);
      expect(byId('pin_shift_view'), findsOneWidget);
    });
  });

  group('UX #16: dialogs', () {
    testWidgets('destructive vs sensitive styling; every Cancel has an id',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester);
      final cs = Theme.of(tester.element(find.byType(Scaffold))).colorScheme;

      Color? filledBackground(String id) => tester
          .widget<FilledButton>(find.descendant(
              of: byId(id), matching: find.byType(FilledButton)))
          .style
          ?.backgroundColor
          ?.resolve({});

      await enterPin24(tester, seed: abandon12, nickname: 'visa');
      await _tap(tester, 'pin24_wipe_all');
      await tester.pumpAndSettle();
      expect(filledBackground('pin24_wipe_all_confirm'), cs.error);
      expect(byId('pin24_wipe_all_cancel'), findsOneWidget);
      await tester.tap(byId('pin24_wipe_all_cancel'));
      await tester.pumpAndSettle();

      await _tap(tester, 'pin_tool_yubikey');
      await tester.pump();
      await _tap(tester, 'yk_source_random');
      await tester.pump();
      await tester.enterText(fieldById('yk_serials'), '12345678');
      await settleDerivation(tester);
      await _tap(tester, 'yk_regenerate');
      await tester.pumpAndSettle();
      expect(filledBackground('yk_regenerate_confirm'), cs.error,
          reason: 'regenerating destroys values that exist nowhere else');
      await tester.tap(byId('yk_regenerate_cancel'));
      await tester.pumpAndSettle();

      await _tap(tester, 'yk_copy_csv');
      await tester.pumpAndSettle();
      expect(filledBackground('yk_csv_confirm'), isNull,
          reason: 'copying is sensitive, not destructive');
      final icon = tester.widget<Icon>(find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(Icon)));
      expect(icon.color, isNot(cs.error));
      await tester.tap(byId('yk_csv_cancel'));
      await tester.pumpAndSettle();
    });
  });

  group('UX #23: accessibility labels and ids', () {
    testWidgets('eye and copy buttons name their field; chips have ids',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester);
      final l = l10n(tester);

      await tester.enterText(fieldById('pin24_seed'), 'abandon ab');
      await tester.pump();
      await _tap(tester, 'pin24_show_words');
      await tester.pump();
      expect(byId('pin24_suggest_2_about'), findsOneWidget);
      await tester.tap(byId('pin24_suggest_2_about'));
      await tester.pump();
      expect(fieldText(tester, 'pin24_seed'), 'abandon about ');

      await _tap(tester, 'pin_tool_yubikey');
      await tester.pump();
      await _tap(tester, 'yk_source_master');
      await tester.pump();
      await tester.enterText(fieldById('yk_master_key'), _masterA);
      await tester.enterText(fieldById('yk_serials'), '12345678');
      await settleDerivation(tester);
      final name = '00 ${ykFields['00']!.name}';
      expect(_tooltip(tester, 'yk_reveal_12345678_00'), l.pinShowField(name));
      expect(_tooltip(tester, 'yk_copy_12345678_00'), l.pinCopyField(name));

      await _tap(tester, 'pin_tool_shift');
      await tester.pump();
      expect(_tooltip(tester, 'pin_shift_vector_eye'),
          l.pinShowField(l.pinShiftFieldVector));
    });

    testWidgets('secret outputs are read aloud only while revealed',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester);
      final l = l10n(tester);
      final handle = tester.ensureSemantics();

      await _tap(tester, 'pin_tool_shift');
      await tester.pump();
      await tester.enterText(fieldById('pin_shift_pin'), '1234');
      await tester.enterText(fieldById('pin_shift_vector'), '3719');
      await tester.pump();
      expect(
          find.bySemanticsLabel(
              l.pinSecretHiddenSemantics(l.pinShiftRowOutputDerived, 4)),
          findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('4 9 4 3')), findsNothing);
      await _tap(tester, 'pin_shift_reveal');
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp('4 9 4 3')), findsOneWidget);

      await _tap(tester, 'pin_show_legacy');
      await tester.pump();
      await _tap(tester, 'pin_tool_legacy');
      await tester.pump();
      await tester.enterText(fieldById('legacy_mask_mask'), '24681357');
      await tester.enterText(
          fieldById('legacy_mask_input'), 'ABCDEFGHIJKLMNOPQRST');
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp('B F L T')), findsNothing);
      await _tap(tester, 'legacy_mask_reveal');
      await tester.pump();
      expect(
          find.bySemanticsLabel(l.pinLegacyOutputSemantics('B F L T A D I P')),
          findsOneWidget);
      handle.dispose();
    });
  });

  group('UX #24: disclosures', () {
    testWidgets('open with the app spring; instantly with reduced motion',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester);
      ExpansionTile tile() => tester.widget<ExpansionTile>(find.descendant(
          of: byId('pin24_threat_model'),
          matching: find.byType(ExpansionTile)));
      expect(tile().expansionAnimationStyle?.curve, same(appSpring));
      expect(tile().expansionAnimationStyle?.reverseCurve, same(appSpring));

      await pumpPin(
        tester,
        child: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: const PinSection(),
          ),
        ),
      );
      expect(tile().expansionAnimationStyle, AnimationStyle.noAnimation);
    });
  });

  group('PIN 24 small states', () {
    testWidgets(
        'UX #3: after "I understand" the description folds away; '
        '"Show legacy tools" sits at the bottom', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      mockPrivacyChannel(tester);
      // First run: everything above the seed field.
      setPinPrefs({'pin.pin24.banner_ack': false});
      await pumpPin(tester);
      final l = l10n(tester);
      expect(find.text(l.pin24Summary), findsOneWidget);
      final firstRun = tester.getRect(byId('pin24_seed')).top;

      // Acknowledged: the banner stays, the description is folded away.
      setPinPrefs();
      await tester.pumpWidget(const SizedBox());
      await pumpPin(tester);
      expect(byId('pin24_about'), findsOneWidget);
      expect(find.text(l.pin24Summary), findsNothing);
      expect(find.text(l.pin24Banner), findsOneWidget);
      final acknowledged = tester.getRect(byId('pin24_seed')).top;
      expect(acknowledged, lessThan(firstRun - 150));
      // "Show legacy tools" no longer sits above the tool.
      expect(tester.getRect(byId('pin_show_legacy')).top,
          greaterThan(acknowledged));
      await tester.ensureVisible(byId('pin_show_legacy'));
      await tester.pump();
      expect(tester.getRect(byId('pin_show_legacy')).top,
          greaterThan(tester.getRect(byId('pin24_selftest')).bottom));
    });

    testWidgets('UX #15: first run explains the lock at full contrast',
        (tester) async {
      setPinPrefs({'pin.pin24.banner_ack': false});
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester);
      final l = l10n(tester);
      expect(find.text(l.pin24Summary), findsOneWidget);
      final text = tester.widget<Text>(find.text(l.pin24AckRequired));
      final cs = Theme.of(tester.element(find.byType(Scaffold))).colorScheme;
      expect(text.style?.color, cs.onSurface);
      expect(byId('pin24_ack_required'), findsOneWidget);
    });

    testWidgets('UX #14: short nickname label, rule in the helper',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester);
      final l = l10n(tester);
      final field = tester.widget<TextField>(find.descendant(
          of: byId('pin24_nickname'), matching: find.byType(TextField)));
      expect(field.decoration?.labelText, l.pin24NicknameLabel);
      expect(l.pin24NicknameLabel.length, lessThan(20));
      expect(field.decoration?.helperText, contains('case-sensitive'));
    });

    testWidgets('UX #20: a passphrase shows while its section is folded',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester);
      final l = l10n(tester);
      await _tap(tester, 'pin24_passphrase_section');
      await tester.pumpAndSettle();
      await tester.enterText(fieldById('pin24_passphrase'), 'TREZOR');
      await tester.pump();
      await tester.tap(find.text(l.pin24PassphraseTitle));
      await tester.pumpAndSettle();
      expect(fieldById('pin24_passphrase'), findsNothing, reason: 'folded');
      expect(find.text(l.pin24PassphraseSet), findsOneWidget);
    });

    testWidgets('C-UI-t: passphrase with an edge space shows the chip',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester);
      final l = l10n(tester);
      await _tap(tester, 'pin24_passphrase_section');
      await tester.pumpAndSettle();
      await tester.enterText(fieldById('pin24_passphrase'), ' x');
      await tester.pump();
      expect(byId('pin24_passphrase_whitespace'), findsOneWidget);
      expect(find.text(l.pin24PassphraseWhitespace), findsOneWidget);
      await tester.enterText(fieldById('pin24_passphrase'), 'x');
      await tester.pump();
      expect(byId('pin24_passphrase_whitespace'), findsNothing);
    });

    testWidgets('C-UI-t: the special-characters help lists both sets',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester);
      final l = l10n(tester);
      await _tap(tester, 'pin24_mode_password');
      await tester.pump();
      await _tap(tester, 'pin24_charset_help');
      await tester.pumpAndSettle();
      expect(find.text(l.pin24SpecialsBody), findsOneWidget);
      expect(find.text(kCharsets[6]), findsOneWidget);
      expect(find.text(kCharsets[7]), findsOneWidget);
      await tester.tap(byId('pin24_specials_ok'));
      await tester.pumpAndSettle();
      expect(find.text(l.pin24SpecialsBody), findsNothing);
    });

    testWidgets('C-UI-t: a failing engine check says FAILED', (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, overrides: [
        pin24SelfTestVectorsProvider.overrideWithValue(const [
          Pin24SelfTestVector(0x07, 'gmail', 'not-the-real-output!'),
          ...kPin24OfficialVectors,
        ]),
      ]);
      final l = l10n(tester);
      await _tap(tester, 'pin24_selftest');
      await tester.pump();
      await tester.pump();
      expect(find.text(l.pin24SelfTestFailed(1, 11)), findsOneWidget);
      expect(find.text(l.pin24SelfTestOk(10, 11)), findsNothing);
    });
  });

  group('C-UI-t: test-build screenshot chip', () {
    for (final allowed in [true, false]) {
      testWidgets('isScreenshotsAllowedBuild = $allowed', (tester) async {
        useTallSurface(tester);
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(
          const MethodChannel(PrivacyService.channelName),
          (call) async => switch (call.method) {
            'isScreenshotsAllowedBuild' => allowed,
            'isScreenCaptured' => false,
            _ => true,
          },
        );
        messenger.setMockMethodCallHandler(
            const MethodChannel(PrivacyService.eventChannelName),
            (call) async => null);
        addTearDown(() {
          messenger.setMockMethodCallHandler(
              const MethodChannel(PrivacyService.channelName), null);
          messenger.setMockMethodCallHandler(
              const MethodChannel(PrivacyService.eventChannelName), null);
        });
        await pumpPin(tester);
        final l = l10n(tester);
        expect(byId('pin_screenshots_allowed'),
            allowed ? findsOneWidget : findsNothing);
        expect(find.text(l.pinScreenshotsAllowedBuild),
            allowed ? findsOneWidget : findsNothing);
      });
    }
  });

  group('UX #18 / #8', () {
    testWidgets('RTL: field name and origin label keep a gap', (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, locale: const Locale('ar'));
      final l = l10n(tester);
      await _tap(tester, 'pin_tool_yubikey');
      await tester.pump();
      await _tap(tester, 'yk_source_random');
      await tester.pump();
      await tester.enterText(fieldById('yk_serials'), '12345678');
      await settleDerivation(tester);
      final row = byId('yk_row_12345678_24');
      final name = tester.getRect(find.descendant(
          of: row, matching: find.text('24 ${ykFields['24']!.name}')));
      final origin = tester.getRect(
          find.descendant(of: row, matching: find.text(l.pinYkOriginRandom)));
      // RTL: the name sits at the start (right), the origin at the end.
      expect(name.left - origin.right, greaterThanOrEqualTo(8));
    });

    testWidgets('the clipboard promise matches the platform', (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester);
      final l = l10n(tester);
      expect(l.pin24ThreatProtectsBody, isNot(contains('not shared')));
      expect(l.pinYkCsvConfirmBody(3), isNot(contains('not shared')));
      expect(pinClipboardPrivacyNote(l), l.pinClipboardNoteAndroid);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        expect(pinClipboardPrivacyNote(l), l.pinClipboardNoteIos);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
      await _tap(tester, 'pin24_threat_model');
      await tester.pumpAndSettle();
      expect(find.textContaining(l.pinClipboardNoteAndroid), findsOneWidget);
    });
  });
}
