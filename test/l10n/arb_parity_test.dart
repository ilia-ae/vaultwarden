// The five ARB files must stay in lockstep: same keys, placeholders only
// from the template, zh identical to zh_Hans, and real (non-empty)
// translations of every PIN key.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
}
