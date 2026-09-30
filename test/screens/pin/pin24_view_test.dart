import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vault_approver/screens/pin/pin24_engine.dart';
import 'package:vault_approver/screens/pin/pin_prefs.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';
import 'package:vault_approver/screens/pin/pin_widgets.dart';

import 'pin_harness.dart';

/// Text widgets (not the fields themselves) whose text contains [needle].
Finder visibleTextContaining(String needle) => find.byWidgetPredicate(
      (w) =>
          (w is Text && (w.data ?? '').contains(needle)) ||
          (w is RichText && w.text.toPlainText().contains(needle)),
      description: 'Text containing "$needle"',
    );

void main() {
  setUp(setPinPrefs);

  group('PIN 24 public vectors', () {
    testWidgets('abandon×11 about + "visa" → 0853, length 12 → 085388806588',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      await enterPin24(tester, seed: abandon12, nickname: 'visa');
      expect(find.text(l.pin24StatusOk(12)), findsOneWidget);
      expect(find.text(l.pin24WordsCounter(12, 12)), findsOneWidget);
      expect(displayedPin(tester), '0853');
      expect(find.text(l.pin24PinCaption('visa', 4)), findsOneWidget);

      await tester.tap(byId('pin24_len_12'));
      await settleDerivation(tester);
      expect(displayedPin(tester), '085388806588');
    });

    testWidgets('full password shows spaces as ␣ (abandon12 / "Visa")',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);

      await enterPin24(tester, seed: abandon12, nickname: 'Visa');
      expect(displayedPin(tester), '0639');
      await tester.tap(byId('pin24_show_full'));
      await tester.pump();
      expect(
          find.text(withVisibleSpaces(' 063_ 937472--6_8-72')), findsOneWidget);
    });

    testWidgets('BIP39 passphrase "TREZOR" changes the PIN (abandon12/visa)',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);

      await enterPin24(
        tester,
        seed: abandon12,
        nickname: 'visa',
        passphrase: 'TREZOR',
      );
      expect(displayedPin(tester), '7434');
    });

    testWidgets('Speculos seed + "gmail": PIN 7078 and official 0x07 password',
        (tester) async {
      useTallSurface(tester);
      final channel = mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      await enterPin24(tester, seed: speculos24, nickname: 'gmail');
      expect(displayedPin(tester), '7078');

      await tester.tap(byId('pin24_mode_password'));
      await settleDerivation(tester);
      // Official LedgerHQ vector: A-Z + a-z + 0-9 (mask 0x07), 4-char groups.
      expect(outputText(tester), 'xNX8IQO4vP0ucO41J6JW');
      expect(
        find.text(
            l.pin24PasswordCaption(ltrIsolate('A-Z + a-z + 0-9'), 'gmail')),
        findsOneWidget,
      );

      // Tap copies the raw 20 characters through the privacy channel.
      await tester.tap(byId('pin24_output'));
      await tester.pump();
      final copy = channel.named('copySensitive').single;
      expect(
          copy.arguments, {'text': 'xNX8IQO4vP0ucO41J6JW', 'ttlSeconds': 60});
      expect(find.text(l.pinCopied), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1300));
      expect(find.text(l.pinCopied), findsNothing);
    });

    testWidgets('zero padding is announced (Speculos / "svc44" / length 12)',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      await tester.tap(byId('pin24_len_12'));
      await tester.pump();
      await enterPin24(tester, seed: speculos24, nickname: 'svc44');
      expect(displayedPin(tester), '738156850000');
      expect(find.text(l.pin24PaddingWarning(10, 2)), findsOneWidget);
    });
  });

  group('gating and validation', () {
    testWidgets('three gates in order: phrase → nickname → charset',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      expect(find.text(l.pin24Gate1), findsOneWidget);
      // A nickname alone does not pass gate 1.
      await tester.enterText(fieldById('pin24_nickname'), 'visa');
      await tester.pump();
      expect(find.text(l.pin24Gate1), findsOneWidget);
      await tester.enterText(fieldById('pin24_nickname'), '');
      await tester.enterText(fieldById('pin24_seed'), abandon12);
      await tester.pump();
      expect(find.text(l.pin24Gate1), findsNothing);
      expect(find.text(l.pin24Gate2), findsOneWidget);

      await tester.enterText(fieldById('pin24_nickname'), 'visa');
      await tester.tap(byId('pin24_mode_password'));
      await tester.pump();
      for (final c in ['upper', 'lower', 'digits']) {
        await tester.tap(byId('pin24_cs_$c'));
        await tester.pump();
      }
      expect(find.text(l.pin24Gate3), findsOneWidget);
      expect(find.text(l.pin24CharsetNone), findsOneWidget);

      // Tapping Password again restores A-Z, a-z, 0-9.
      await tester.tap(byId('pin24_mode_password'));
      await settleDerivation(tester);
      expect(find.text(l.pin24Gate3), findsNothing);
      expect(outputText(tester), hasLength(20));
    });

    testWidgets('status messages: count, wordlist, checksum', (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      await tester.enterText(fieldById('pin24_seed'), 'abandon abandon');
      await tester.pump();
      expect(find.text(l.pin24StatusCount(2)), findsOneWidget);

      await tester.enterText(
          fieldById('pin24_seed'), '${'abandon ' * 11}xyzzy');
      await tester.pump();
      expect(find.text(l.pin24StatusWordlist), findsOneWidget);
      expect(find.text(l.pin24InvalidMasked(ltrIsolate('12'))), findsOneWidget);
      expect(visibleTextContaining('xyzzy'), findsNothing);

      await tester.enterText(fieldById('pin24_seed'), 'abandon ' * 12);
      await tester.pump();
      expect(find.text(l.pin24StatusChecksum), findsOneWidget);
      expect(find.text(l.pin24Gate1), findsOneWidget);
    });

    testWidgets('broken UTF-16: passphrase error is mapped, never echoed',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      await enterPin24(
        tester,
        seed: abandon12,
        nickname: 'visa',
        passphrase: 'qzx\uDC00qzx',
      );
      expect(find.text(l.pin24ErrorPassphraseUtf8), findsOneWidget);
      expect(visibleTextContaining('surrogates not allowed'), findsNothing);
      expect(visibleTextContaining('codec'), findsNothing);
      expect(visibleTextContaining('qzx'), findsNothing);
      expect(byId('pin24_output'), findsNothing);
    });

    testWidgets('broken UTF-16 in the visible nickname is dropped with a hint',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      await enterPin24(tester, seed: abandon12, nickname: 'vi\uD800sa');
      expect(fieldText(tester, 'pin24_nickname'), 'visa');
      expect(find.text(l.pin24NicknameBrokenRemoved), findsOneWidget);
      expect(displayedPin(tester), '0853');
    });

    testWidgets('mirror masks every word with a fixed width until 👁 is on',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      await tester.enterText(fieldById('pin24_seed'), 'abandon zoo xyzzy');
      await tester.pump();
      expect(find.text(PinWordCells.mask), findsNWidgets(3));
      expect(find.text('abandon'), findsNothing);
      expect(find.text('zoo'), findsNothing);
      // 3 typed words → 12 target cells; 9 empty ones show a single bullet.
      expect(find.text('•'), findsNWidgets(9));

      final handle = tester.ensureSemantics();
      expect(
        find.bySemanticsLabel(l.pinWordCellSemantics(3, l.pinWordStateInvalid)),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel(RegExp('xyzzy')), findsNothing);
      handle.dispose();

      await tester.tap(byId('pin24_show_words'));
      await tester.pump();
      expect(find.text('abandon'), findsOneWidget);
      expect(find.text('zoo'), findsOneWidget);
      expect(find.text(l.pin24InvalidRevealed(ltrIsolate('“xyzzy” (#3)'))),
          findsOneWidget);
    });
  });

  group('entry helpers', () {
    testWidgets('completions only with 👁 on; tap accepts', (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      await tester.enterText(fieldById('pin24_seed'), 'abandon ab');
      await tester.pump();
      expect(find.text(l.pin24PartialMasked(ltrIsolate('2'))), findsOneWidget);
      expect(find.byType(ActionChip), findsNothing);

      await tester.tap(byId('pin24_show_words'));
      await tester.pump();
      final chips = tester
          .widgetList<ActionChip>(find.byType(ActionChip))
          .map((c) => (c.label as Text).data)
          .toList();
      expect(chips, ['abandon', 'ability', 'able', 'about', 'above', 'absent']);

      await tester.tap(find.widgetWithText(ActionChip, 'about'));
      await tester.pump();
      expect(fieldText(tester, 'pin24_seed'), 'abandon about ');
    });

    testWidgets('a unique 4-letter prefix is completed on a space, not before',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      expect(find.text(l.pin24AutoCompleteHint), findsOneWidget);
      await tester.enterText(fieldById('pin24_seed'), 'aba');
      await tester.pump();
      await tester.enterText(fieldById('pin24_seed'), 'aban');
      await tester.pump();
      expect(fieldText(tester, 'pin24_seed'), 'aban', reason: 'still typing');
      await tester.enterText(fieldById('pin24_seed'), 'aban ');
      await tester.pump();
      expect(fieldText(tester, 'pin24_seed'), 'abandon ');
    });

    // UX #1: typing each word in full, key by key, as written on the
    // recovery sheet, must give exactly the typed phrase (the old
    // auto-complete turned "abandon" into "abandon don").
    for (final (name, phrase, pin) in [
      ('abandon×11 about', abandon12, '0853'),
      ('Speculos 24 words', speculos24, null),
    ]) {
      testWidgets('typing $name key by key ends canonical', (tester) async {
        useTallSurface(tester);
        mockPrivacyChannel(tester);
        await pumpPin(tester, tool: PinTool.pin24);
        final l = l10n(tester);
        await tester.enterText(fieldById('pin24_nickname'), 'visa');
        for (final ch in phrase.split('')) {
          // A keyboard appends to whatever the field holds now.
          await tester.enterText(
              fieldById('pin24_seed'), fieldText(tester, 'pin24_seed') + ch);
        }
        await settleDerivation(tester);
        expect(fieldText(tester, 'pin24_seed'), phrase);
        final words = phrase.split(' ').length;
        expect(find.text(l.pin24StatusOk(words)), findsOneWidget);
        if (pin != null) expect(displayedPin(tester), pin);
        // Typed, not pasted.
        expect(byId('pin24_clear_clipboard'), findsNothing);
      });
    }

    testWidgets('4 letters and a space per word are enough', (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      const short =
          'aban aban aban aban aban aban aban aban aban aban aban abou ';
      for (final ch in short.split('')) {
        await tester.enterText(
            fieldById('pin24_seed'), fieldText(tester, 'pin24_seed') + ch);
      }
      expect(fieldText(tester, 'pin24_seed'), '$abandon12 ');
    });

    testWidgets('prefix words need confirmation (act → action…)',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      await tester.enterText(fieldById('pin24_seed'), 'ac');
      await tester.pump();
      await tester.enterText(fieldById('pin24_seed'), 'act');
      await tester.pump();
      expect(fieldText(tester, 'pin24_seed'), 'act');
      expect(find.text(l.pin24AmbiguousWord(1)), findsOneWidget);
      await tester.tap(byId('pin24_confirm_word'));
      await tester.pump();
      expect(fieldText(tester, 'pin24_seed'), 'act ');
      expect(find.text(l.pin24AmbiguousWord(1)), findsNothing);
    });

    testWidgets('glued words (lost line breaks) can be split', (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      await tester.enterText(
          fieldById('pin24_seed'), '${'abandon ' * 10}abandonabout');
      await tester.pump();
      expect(find.text(l.pin24GluedWords(ltrIsolate('11'))), findsOneWidget);
      await tester.tap(byId('pin24_split_glued'));
      await tester.pump();
      expect(find.text(l.pin24StatusOk(12)), findsOneWidget);
    });

    testWidgets('non-ASCII letters are called out', (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      await tester.enterText(fieldById('pin24_seed'), 'abandon abóut');
      await tester.pump();
      expect(find.text(l.pin24NonAscii), findsOneWidget);
    });

    testWidgets('after a paste the clipboard can be cleared', (tester) async {
      useTallSurface(tester);
      final channel = mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      await tester.enterText(fieldById('pin24_seed'), abandon12);
      await tester.pump();
      expect(find.text(l.pinPastedStillOnClipboard), findsOneWidget);
      await tester.tap(byId('pin24_clear_clipboard'));
      await tester.pump();
      expect(channel.named('clearClipboard'), hasLength(1));
      expect(find.text(l.pinPastedStillOnClipboard), findsNothing);
    });

    testWidgets('nickname warnings: edge space, non-ASCII, > 19 bytes',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      await tester.enterText(fieldById('pin24_nickname'), ' café');
      await tester.pump();
      expect(find.text(l.pin24NicknameWhitespace), findsOneWidget);
      expect(find.text(l.pin24NicknameNonAscii), findsOneWidget);
      await tester.enterText(fieldById('pin24_nickname'), 'a' * 20);
      await tester.pump();
      expect(find.text(l.pin24NicknameTooLong(20, 19)), findsOneWidget);
    });
  });

  group('wipes and lifecycle', () {
    testWidgets('paused wipes inputs, outputs and the cached seed',
        (tester) async {
      useTallSurface(tester);
      resetLifecycleOnTearDown(tester);
      mockPrivacyChannel(tester);
      final container = await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      await enterPin24(tester, seed: abandon12, nickname: 'visa');
      final cache = container.read(pinSeedProvider);
      expect(cache.hasSeed, isTrue);
      await tester.tap(byId('pin24_show_words'));
      await tester.pump();

      setLifecycle(tester, AppLifecycleState.paused);
      await tester.pump();
      expect(cache.hasSeed, isFalse);

      setLifecycle(tester, AppLifecycleState.resumed);
      await tester.pump();
      expect(fieldText(tester, 'pin24_seed'), isEmpty);
      expect(fieldText(tester, 'pin24_nickname'), isEmpty);
      expect(byId('pin24_output'), findsNothing);
      expect(find.text(l.pin24Gate1), findsOneWidget);
      expect(find.text(l.pinWipedBackground), findsOneWidget);
      final showWords = tester.widget<SwitchListTile>(find.descendant(
          of: byId('pin24_show_words'), matching: find.byType(SwitchListTile)));
      expect(showWords.value, isFalse);
    });

    testWidgets('inactive only hides; resumed shows the same input',
        (tester) async {
      useTallSurface(tester);
      resetLifecycleOnTearDown(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      await enterPin24(tester, seed: abandon12, nickname: 'visa');
      setLifecycle(tester, AppLifecycleState.inactive);
      await tester.pump();
      expect(find.text(l.pinHiddenInactive), findsOneWidget);
      // Offstage: nothing of the tool is painted or hit-testable.
      expect(byId('pin24_output'), findsNothing);
      expect(byId('pin24_output').hitTestable(), findsNothing);

      setLifecycle(tester, AppLifecycleState.resumed);
      await tester.pump();
      expect(find.text(l.pinHiddenInactive), findsNothing);
      expect(fieldText(tester, 'pin24_seed'), abandon12);
      expect(displayedPin(tester), '0853');
    });

    testWidgets('120 s without interaction wipes everything', (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      final container = await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      await enterPin24(tester, seed: abandon12, nickname: 'visa');
      await tester.pump(const Duration(seconds: 119));
      expect(fieldText(tester, 'pin24_seed'), abandon12);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(fieldText(tester, 'pin24_seed'), isEmpty);
      expect(container.read(pinSeedProvider).hasSeed, isFalse);
      expect(find.text(l.pinWipedInactivity), findsOneWidget);
    });

    testWidgets('🧹 keeps nickname; 🚨 asks first and clears everything',
        (tester) async {
      useTallSurface(tester);
      final channel = mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      await enterPin24(tester, seed: abandon12, nickname: 'visa');
      await tester.tap(byId('pin24_wipe_seed'));
      await tester.pump();
      expect(fieldText(tester, 'pin24_seed'), isEmpty);
      expect(fieldText(tester, 'pin24_nickname'), 'visa');
      // The seed was pasted (one big edit), so the wipe took it off the
      // clipboard too, and says so.
      expect(find.text(l.pinWipedClipboardToo(l.pinWipedSeed)), findsOneWidget);
      expect(channel.named('clearClipboard'), hasLength(1));

      await enterPin24(tester, seed: abandon12, nickname: 'visa');
      await tester.tap(byId('pin24_wipe_all'));
      await tester.pumpAndSettle();
      expect(find.text(l.pin24WipeAllBody), findsOneWidget);
      await tester.tap(find.text(l.cancel));
      await tester.pumpAndSettle();
      expect(displayedPin(tester), '0853');

      await tester.tap(byId('pin24_wipe_all'));
      await tester.pumpAndSettle();
      await tester.tap(byId('pin24_wipe_all_confirm'));
      await tester.pumpAndSettle();
      expect(fieldText(tester, 'pin24_seed'), isEmpty);
      expect(fieldText(tester, 'pin24_nickname'), isEmpty);
      expect(byId('pin24_output'), findsNothing);
    });
  });

  group('prefs and acknowledgement', () {
    testWidgets('seed field stays locked until "I understand"', (tester) async {
      SharedPreferences.setMockInitialValues({});
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);
      final l = l10n(tester);

      final field = tester.widget<TextField>(find.descendant(
          of: byId('pin24_seed'), matching: find.byType(TextField)));
      expect(field.enabled, isFalse);
      expect(find.text(l.pin24AckRequired), findsOneWidget);

      await tester.tap(byId('pin24_ack'));
      await tester.pumpAndSettle();
      expect(byId('pin24_ack'), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(PinPrefs.kPin24BannerAck), isTrue);
      final enabled = tester.widget<TextField>(find.descendant(
          of: byId('pin24_seed'), matching: find.byType(TextField)));
      expect(enabled.enabled, isTrue);
      // The banner itself is shown every time.
      expect(find.text(l.pin24Banner), findsOneWidget);
    });

    testWidgets('stored length is clamped; nothing secret is stored',
        (tester) async {
      setPinPrefs({PinPrefs.kPin24Length: 99});
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);

      await enterPin24(tester, seed: abandon12, nickname: 'visa');
      expect(displayedPin(tester), '085388806588');

      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        expect(PinPrefs.allKeys, contains(key));
        final value = '${prefs.get(key)}';
        expect(value, isNot(contains('abandon')));
        expect(value, isNot(contains('visa')));
      }
    });

    testWidgets('secret fields carry the anti-leak flags', (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24);

      for (final id in ['pin24_seed', 'pin24_passphrase', 'pin24_nickname']) {
        if (find
            .descendant(of: byId(id), matching: find.byType(TextField))
            .evaluate()
            .isEmpty) {
          await tester.tap(byId('pin24_passphrase_section'));
          await tester.pumpAndSettle();
        }
        final f = tester.widget<TextField>(
            find.descendant(of: byId(id), matching: find.byType(TextField)));
        expect(f.autocorrect, isFalse, reason: id);
        expect(f.enableSuggestions, isFalse, reason: id);
        expect(f.enableIMEPersonalizedLearning, isFalse, reason: id);
        expect(f.smartDashesType, SmartDashesType.disabled, reason: id);
        expect(f.smartQuotesType, SmartQuotesType.disabled, reason: id);
        expect(f.textCapitalization, TextCapitalization.none, reason: id);
        expect(f.autofillHints, isNull, reason: id);
        expect(f.restorationId, isNull, reason: id);
        expect(f.obscureText, id != 'pin24_nickname', reason: id);
      }
      final nick = tester.widget<TextField>(find.descendant(
          of: byId('pin24_nickname'), matching: find.byType(TextField)));
      expect(nick.keyboardType, TextInputType.visiblePassword);
    });

    testWidgets('digits and words stay left-to-right in Arabic',
        (tester) async {
      useTallSurface(tester);
      mockPrivacyChannel(tester);
      await pumpPin(tester, tool: PinTool.pin24, locale: const Locale('ar'));

      await enterPin24(tester, seed: abandon12, nickname: 'visa');
      expect(displayedPin(tester), '0853');
      final cells = find.byType(PinDigitCells);
      final dir = tester.widget<Directionality>(find
          .descendant(of: cells, matching: find.byType(Directionality))
          .first);
      expect(dir.textDirection, TextDirection.ltr);
      expect(
        Directionality.of(tester.element(find.byType(PinWordCells))),
        TextDirection.rtl,
      );
    });
  });

  test('error codes map to fixed kinds; compute never throws', () {
    expect(pin24ErrorKind('BIP39_INVALID'), Pin24ErrorKind.bip39Invalid);
    expect(pin24ErrorKind('PASSPHRASE_NOT_UTF8'),
        Pin24ErrorKind.passphraseNotUtf8);
    expect(pin24ErrorKind('NICKNAME_NOT_UTF8'), Pin24ErrorKind.nicknameNotUtf8);
    expect(pin24ErrorKind('NICKNAME_EMPTY'), Pin24ErrorKind.nicknameEmpty);
    expect(pin24ErrorKind('BIP32_INVALID'), Pin24ErrorKind.bip32Invalid);
    for (final other in [
      'SEED_LENGTH',
      'SIZE_NOT_POSITIVE',
      'MODULO_RANGE',
      pin24UnexpectedError,
      'anything'
    ]) {
      expect(pin24ErrorKind(other), Pin24ErrorKind.generic, reason: other);
    }
    final r = pin24Compute(const Pin24Request(
      canonicalPhrase: abandon12,
      nickname: 'vi\uD800sa',
      mode: Pin24Mode.pin,
      length: 4,
      setMask: 0,
    ));
    expect(r.errorCode, 'NICKNAME_NOT_UTF8');
    expect(r.pin, isNull);
    expect(r.freshSeed, isNull);
    expect('$r', isNot(contains('visa')));
  });

  test('pin24Compute zeroes a cached seed and matches the phrase path', () {
    final fresh = pin24Compute(const Pin24Request(
      canonicalPhrase: abandon12,
      nickname: 'visa',
      mode: Pin24Mode.pin,
      length: 4,
      setMask: 0,
    ));
    expect(fresh.pin, '0853');
    final seed = fresh.freshSeed!;
    expect(seed, hasLength(64));
    final copy = Uint8List.fromList(seed);
    final cached = pin24Compute(Pin24Request(
      cachedSeed: copy,
      nickname: 'visa',
      mode: Pin24Mode.pin,
      length: 12,
      setMask: 0,
    ));
    expect(cached.pin, '085388806588');
    expect(cached.freshSeed, isNull);
    expect(copy.every((b) => b == 0), isTrue);
  });
}
