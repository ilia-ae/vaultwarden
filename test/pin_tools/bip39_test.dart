// BIP39 wordlist, the PIN 24 seed-entry parser/validator (pin24_ui.py) and
// the python-mnemonic checksum. Fixtures were generated from the Python code.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:vault_approver/pin_tools/bip39.dart';
import 'package:vault_approver/pin_tools/bip39_english.dart';

const _fixtureDir = 'test/pin_tools/fixtures';

Map<String, dynamic> _load(String name) =>
    jsonDecode(File('$_fixtureDir/$name').readAsStringSync())
        as Map<String, dynamic>;

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

const _abandon12 = 'abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon about';
const _speculos = 'glory promote mansion idle axis finger extra february '
    'uncover one trip resource lawn turtle enact monster seven myth punch '
    'hobby comfort wild raise skin';

List<String> _repeat(String w, int n) => List.filled(n, w);

void main() {
  final props = _load('bip39_wordlist_props.json');
  final ui = _load('pin24_ui_parser.json');

  group('English wordlist', () {
    test('matches canonical english.txt (SHA-256 over LF-joined lines)', () {
      expect(bip39English, hasLength(props['count']));
      final text = '${bip39English.join('\n')}\n';
      final digest = SHA256Digest().process(
        Uint8List.fromList(utf8.encode(text)),
      );
      expect(_hex(digest), props['sha256_english_txt']);
      expect(
        _hex(digest),
        '2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda',
      );
    });

    test('properties: lengths, unique 4-letter prefixes, index lookup', () {
      final lengths = bip39English.map((w) => w.length);
      expect(lengths.reduce((a, b) => a < b ? a : b), props['min_len']);
      expect(lengths.reduce((a, b) => a > b ? a : b), props['max_len']);
      final first4 = {
        for (final w in bip39English) w.length < 4 ? w : w.substring(0, 4),
      };
      expect(first4.length == bip39English.length, props['unique_first4']);
      for (var i = 0; i < bip39English.length; i++) {
        expect(bip39WordIndex(bip39English[i]), i);
      }
      expect(bip39WordIndex('abandonx'), isNull);
      expect(isBip39Word('Abandon'), isFalse);
    });

    test('the 49 words that are prefixes of other words', () {
      final expected = (props['words_that_are_prefix_of_other_words'] as List)
          .cast<String>();
      expect(expected, hasLength(49));
      expect(bip39English.where(isAmbiguousPrefixWord).toList(), expected);
      expect(isAmbiguousPrefixWord('acti'), isFalse);
      expect(isAmbiguousPrefixWord(''), isFalse);
    });
  });

  group('parseSeedWords (pin24_ui._parse_seed_words)', () {
    void checkParse(String name, Map<String, dynamic> v) {
      final input = v['input'] as String;
      final units = v['utf16'] as List?;
      if (units != null) expect(input.codeUnits, units, reason: name);
      final parsed = parseSeedWords(input);
      expect(parsed.words, v['words'], reason: name);
      expect(parsed.invalidPositions, v['invalid_positions_0based'],
          reason: name);
      expect(parsed.partialPositions, v['partial_positions_0based'],
          reason: name);
      expect(parsed.words.length, v['word_count'], reason: name);
      expect(parsed.states, hasLength(parsed.words.length));
      expect(parsed.canonical, (v['words'] as List).join(' '));
      expect(targetWordCount(parsed.words.length), v['target_count'],
          reason: name);
      final validation = validateWords(parsed.words);
      expect(validation.isValid, v['valid'], reason: name);
      expect(validation.message, v['status_message'], reason: name);
      for (var i = 0; i < parsed.words.length; i++) {
        final w = parsed.words[i];
        final want = isBip39Word(w)
            ? Bip39WordState.valid
            : (parsed.partialPositions.contains(i)
                ? Bip39WordState.partial
                : Bip39WordState.invalid);
        expect(parsed.states[i], want, reason: '$name #$i');
      }
    }

    final parse = (ui['parse'] as Map).cast<String, dynamic>();
    test('fixture has the 17 source cases', () => expect(parse, hasLength(17)));
    parse.forEach((name, v) {
      test(name, () => checkParse(name, (v as Map).cast<String, dynamic>()));
    });
    ((ui['parse_extra'] as Map).cast<String, dynamic>()).forEach((name, v) {
      test('extra: $name',
          () => checkParse(name, (v as Map).cast<String, dynamic>()));
    });

    test('result lists are read-only', () {
      final parsed = parseSeedWords('abandon abo');
      expect(() => parsed.words.add('x'), throwsUnsupportedError);
      expect(
        () => parsed.states[0] = Bip39WordState.invalid,
        throwsUnsupportedError,
      );
    });
  });

  group('validateWords (pin24_ui._validate_full_phrase)', () {
    // Inputs as defined in gen_pin24_ui_vectors.py (the fixture keeps only
    // the outcome).
    final cases = <String, List<String>>{
      '0_words': const [],
      '11_words': _repeat('abandon', 11),
      '12_valid': _abandon12.split(' '),
      '12_bad_checksum': _repeat('abandon', 12),
      '13_words': _repeat('abandon', 13),
      '24_valid': [..._repeat('abandon', 23), 'art'],
      '24_speculos_valid': _speculos.split(' '),
      '25_words': _repeat('abandon', 25),
      '12_with_nonword': [..._repeat('abandon', 11), 'zzzz'],
    };
    final expected = (ui['validation'] as Map).cast<String, dynamic>();

    test('covers every fixture case', () {
      expect(cases.keys.toSet(), expected.keys.toSet());
    });
    cases.forEach((name, words) {
      test(name, () {
        final want = (expected[name] as Map).cast<String, dynamic>();
        final v = validateWords(words);
        expect(v.isValid, want['valid']);
        expect(v.message, want['message']);
        expect(v.wordCount, words.length);
      });
    });

    test('status order: count before wordlist before checksum', () {
      expect(validateWords(const []).status, Bip39Status.empty);
      expect(validateWords(_repeat('zzz', 11)).status, Bip39Status.wrongCount);
      expect(
          validateWords(_repeat('zzz', 12)).status, Bip39Status.notInWordlist);
      expect(validateWords(_repeat('abandon', 24)).status,
          Bip39Status.badChecksum);
      expect(validateWords(_speculos.split(' ')).status, Bip39Status.ok);
    });
  });

  group('bip39ChecksumValid (python-mnemonic check)', () {
    test('known-good phrases of every length', () {
      final vectors = (_load('pin24_vectors.json')['vectors'] as List)
          .cast<Map<String, dynamic>>();
      final phrases = <String>{
        for (final v in vectors)
          if ((v['tags'] as List).contains('mnemonic-length'))
            v['mnemonic'] as String,
      };
      expect(
        phrases.map((p) => p.split(' ').length).toSet(),
        kSupportedWordCounts.toSet(),
      );
      for (final p in phrases) {
        expect(bip39ChecksumValid(p.split(' ')), isTrue, reason: p);
      }
    });

    test('exactly 2^(11 - checksum bits) last words are valid', () {
      for (final n in kSupportedWordCounts) {
        final prefix = _repeat('abandon', n - 1);
        final valid = [
          for (final w in bip39English)
            if (bip39ChecksumValid([...prefix, w])) w,
        ];
        expect(valid, hasLength(1 << (11 - n * 11 ~/ 33)), reason: '$n');
      }
      expect(bip39ChecksumValid([..._repeat('abandon', 11), 'about']), isTrue);
      expect(bip39ChecksumValid([..._repeat('abandon', 23), 'art']), isTrue);
    });

    test('rejects unsupported counts, non-words and unnormalised words', () {
      expect(bip39ChecksumValid(const []), isFalse);
      expect(bip39ChecksumValid(_repeat('abandon', 11)), isFalse);
      expect(bip39ChecksumValid(_repeat('abandon', 25)), isFalse);
      expect(
        bip39ChecksumValid([..._repeat('abandon', 11), 'ABOUT']),
        isFalse,
      );
      expect(
        bip39ChecksumValid([..._repeat('abandon', 11), 'about ']),
        isFalse,
      );
      expect(bip39ChecksumValid([..._repeat('abandon', 11), 'abou']), isFalse);
    });
  });

  group('targetWordCount (pin24_ui._target_word_count)', () {
    final target = (ui['target_word_count'] as Map).cast<String, dynamic>();
    test('0..30 and out-of-range values', () {
      expect(target, hasLength(34));
      target.forEach((typed, want) {
        expect(targetWordCount(int.parse(typed)), want, reason: typed);
      });
    });
  });

  group('suggestionsForPrefix (pin24_ui._suggestions_for_prefix)', () {
    test('default limit 6, wordlist order', () {
      final sugg = (ui['suggestions'] as Map).cast<String, dynamic>();
      expect(sugg.length, greaterThanOrEqualTo(10));
      sugg.forEach((prefix, want) {
        expect(suggestionsForPrefix(prefix), want, reason: prefix);
      });
    });

    test('explicit limits follow Python slicing', () {
      final cases =
          (ui['suggestions_with_limit'] as Map).cast<String, dynamic>();
      cases.forEach((key, v) {
        final c = (v as Map).cast<String, dynamic>();
        expect(
          suggestionsForPrefix(c['prefix'] as String, limit: c['limit'] as int),
          c['result'],
          reason: key,
        );
      });
    });
  });
}
