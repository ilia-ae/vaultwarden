// The five ARB files must stay in lockstep: same keys, placeholders only
// from the template, zh identical to zh_Hans, and real (non-empty)
// translations of every PIN key.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/l10n/app_localizations.dart';

const _locales = ['en', 'ru', 'ar', 'zh', 'zh_Hans'];

Map<String, dynamic> _load(String locale) =>
    jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync())
        as Map<String, dynamic>;

Set<String> _messageKeys(Map<String, dynamic> arb) =>
    arb.keys.where((k) => !k.startsWith('@')).toSet();

/// Placeholder names used in [message], ignoring ICU plural/select branches.
Set<String> _placeholdersIn(String message) =>
    RegExp(r'\{(\w+)(?=[},])').allMatches(message).map((m) => m[1]!).toSet();

void main() {
  final arbs = {for (final l in _locales) l: _load(l)};
  final template = arbs['en']!;
  final keys = _messageKeys(template);

  test('all five ARB files have exactly the template keys', () {
    for (final l in _locales) {
      final own = _messageKeys(arbs[l]!);
      expect(own.difference(keys), isEmpty, reason: '$l has extra keys');
      expect(keys.difference(own), isEmpty, reason: '$l misses keys');
      expect(arbs[l]!['@@locale'], l);
    }
  });

  test('zh and zh_Hans are identical except @@locale', () {
    final zh = Map.of(arbs['zh']!)..remove('@@locale');
    final hans = Map.of(arbs['zh_Hans']!)..remove('@@locale');
    expect(zh, hans);
  });

  test('placeholders are declared in the template and used consistently', () {
    for (final key in keys) {
      final meta = template['@$key'] as Map<String, dynamic>?;
      final declared =
          ((meta?['placeholders'] as Map<String, dynamic>?) ?? {}).keys.toSet();
      for (final l in _locales) {
        final message = arbs[l]![key] as String;
        expect(_placeholdersIn(message), declared,
            reason: '$l/$key uses ${_placeholdersIn(message)}, '
                'template declares $declared');
      }
    }
  });

  test('PIN keys are translated (non-empty, prefixed, not left in English)',
      () {
    final pinKeys = keys.where((k) => k.startsWith('pin')).toList();
    expect(pinKeys, isNotEmpty);
    // Keys whose text is legitimately the same in every language.
    const universal = {
      'pinTab',
      'pinToolPin24',
      'pinToolShift',
      'pinToolYubikey',
      'pin24WordsCounter',
      'pinYkBioTitle', // product name
    };
    // Russian keeps the BIP39 term "passphrase" (as the spec's RU table does).
    const keptTerms = {
      'ru': {'pin24PassphraseLabel'},
    };
    for (final l in _locales.skip(1)) {
      final untranslated = <String>[];
      for (final key in pinKeys) {
        final text = arbs[l]![key] as String;
        expect(text.trim(), isNotEmpty, reason: '$l/$key');
        if (text == template[key] &&
            !universal.contains(key) &&
            !(keptTerms[l]?.contains(key) ?? false)) {
          untranslated.add(key);
        }
      }
      expect(untranslated, isEmpty, reason: '$l has untranslated PIN keys');
    }
  });

  // C8 UX #17: PinNotice/buttons draw their own icons; emoji in the strings
  // doubled them and were read aloud by screen readers.
  test('PIN strings carry no emoji', () {
    final emoji = RegExp(
        '[\u2600-\u27BF\u2B00-\u2BFF\uFE0F]|[\u{1F000}-\u{1FAFF}]',
        unicode: true);
    for (final l in _locales) {
      for (final key in keys.where((k) => k.startsWith('pin'))) {
        expect(emoji.hasMatch(arbs[l]![key] as String), isFalse,
            reason: '$l/$key');
      }
    }
  });

  // C8 UX #11: terminology.
  test('PIN terminology: modulo, tab, passphrase, formal you, project name',
      () {
    final banned = <String, List<String>>{
      'ar': ['ترديد', 'العلامة', 'الأسطول'],
      'ru': ['парка', 'парк '],
      'zh': ['passphrase', '机群', '你'],
      'zh_Hans': ['passphrase', '机群', '你'],
    };
    for (final MapEntry(key: l, value: words) in banned.entries) {
      for (final key in keys.where((k) => k.startsWith('pin'))) {
        final text = arbs[l]![key] as String;
        for (final w in words) {
          expect(text.contains(w), isFalse, reason: '$l/$key contains "$w"');
        }
      }
    }
    for (final l in _locales) {
      expect(arbs[l]!['pinYkOtpNote'] as String, contains('yubikey-fleet'));
      expect(
          arbs[l]!['pinYkLedgerRestHelp'] as String, contains('yubikey-fleet'));
    }
  });

  // C8 UX #10: counts agree with their nouns.
  test('PIN counts use plural forms (ru, ar, en)', () async {
    final ru = await AppLocalizations.delegate.load(const Locale('ru'));
    final ar = await AppLocalizations.delegate.load(const Locale('ar'));
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    expect(ru.pinYkUsingSeed(24), contains('(24 слова)'));
    expect(ru.pinYkUsingSeed(21), contains('(21 слово)'));
    expect(ru.pinYkUsingSeed(12), contains('(12 слов)'));
    expect(ru.pinYkCsvConfirmBody(22), contains('22 секретных значения'));
    expect(ru.pinYkCsvConfirmBody(27), contains('27 секретных значений'));
    expect(ru.pinShiftFillBoth(4), contains('4 цифры'));
    expect(ru.pinShiftFillBoth(8), contains('8 цифр'));
    expect(ru.pin24NicknameTooLong(22, 19), startsWith('22 байта'));
    expect(ru.pinShiftPaperLegend(4), contains('из 4 цифр'));
    expect(ru.pinShiftPaperLegend(1), contains('из 1 цифры'));
    expect(ru.pinYkSerialsTooMany(32), contains('32 серийника'));
    expect(ar.pin24PinCaption('visa', 4), contains('أول 4 أرقام'));
    expect(ar.pin24PinCaption('visa', 12), contains('أول 12 رقمًا'));
    expect(ar.pin24FullCaption(4), contains('أول 4 أرقام'));
    expect(ar.pinYkCsvConfirmBody(5), contains('5 قيم سرية'));
    expect(ar.pinShiftPaperLegend(12), contains('12 رقمًا'));
    expect(en.pinShiftFillBoth(1), contains('1 digit.'));
    expect(en.pinShiftFillBoth(4), contains('4 digits'));
    expect(en.pin24PaddingWarning(11, 1), contains('1 zero at'));
    expect(en.pinLegacyRevisitWarning(1), contains('1 output character is'));
    for (final l in [ru, ar, en]) {
      expect(l.pinYkMasterOk(32), isNot(contains('(s)')));
      expect(l.pinShiftFillBoth(4), isNot(contains('(')));
    }
  });
}
