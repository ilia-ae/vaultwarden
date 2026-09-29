import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/pin_tools/bip39.dart';
import 'package:vault_approver/screens/pin/pin24_engine.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';

void main() {
  group('auto-complete on a separator', () {
    test('completes a unique ≥4-letter prefix when a separator is typed', () {
      expect(autoAcceptSeedEdit('abandon aban', 'abandon aban '),
          'abandon abandon ');
      expect(autoAcceptSeedEdit('abl', 'abl '), isNull, reason: '< 4 letters');
      expect(autoAcceptSeedEdit('ACTI', 'ACTI '), 'action ');
      // The typed separator is kept.
      expect(autoAcceptSeedEdit('aban', 'aban,'), 'abandon,');
      expect(autoAcceptSeedEdit('aban', 'aban-'), 'abandon-');
      expect(autoAcceptSeedEdit('aban', 'aban\n'), 'abandon\n');
    });

    test('never completes while a word is still being typed', () {
      // The old behaviour completed here and the next keystrokes became a
      // junk word ("abandon don").
      expect(autoAcceptSeedEdit('aba', 'aban'), isNull);
      expect(autoAcceptSeedEdit('abandon aba', 'abandon aban'), isNull);
      expect(autoAcceptSeedEdit('aband', 'abando'), isNull);
    });

    test('never fires on pastes, edits in the middle, full words or no match',
        () {
      expect(autoAcceptSeedEdit('', 'aban '), isNull, reason: 'paste');
      expect(autoAcceptSeedEdit('aban x', 'aban  x'), isNull, reason: 'middle');
      expect(autoAcceptSeedEdit('xyzz', 'xyzz '), isNull, reason: 'no match');
      expect(autoAcceptSeedEdit('abandon', 'abandon '), isNull,
          reason: 'already a word');
      expect(autoAcceptSeedEdit('abou', 'aboué'), isNull,
          reason: 'not an ASCII separator');
    });

    test('the 49 prefix words are never extended', () {
      for (final w in ['act', 'art', 'you', 'win']) {
        expect(isAmbiguousPrefixWord(w), isTrue);
        expect(autoAcceptSeedEdit(w, '$w '), isNull);
      }
    });

    /// Types [phrase] one key at a time the way a keyboard does: each key is
    /// appended to whatever the field holds after the previous one.
    String typeKeyByKey(String phrase) {
      var field = '';
      for (final ch in phrase.split('')) {
        final next = '$field$ch';
        field = autoAcceptSeedEdit(field, next) ?? next;
      }
      return field;
    }

    test('typing whole words key by key ends with exactly what was typed', () {
      const abandon = 'abandon abandon abandon abandon abandon abandon '
          'abandon abandon abandon abandon abandon about';
      const speculos = 'glory promote mansion idle axis finger extra february '
          'uncover one trip resource lawn turtle enact monster seven myth '
          'punch hobby comfort wild raise skin';
      expect(typeKeyByKey(abandon), abandon);
      expect(typeKeyByKey(speculos), speculos);
      // Four letters and a space per word are enough.
      expect(typeKeyByKey('aban aban abou '), 'abandon abandon about ');
      expect(typeKeyByKey('glor prom mans '), 'glory promote mansion ');
    });
  });

  group('analysis', () {
    test('flags a still-typed prefix word for confirmation', () {
      final a = analyzeSeedText('abandon act');
      expect(a.pendingAmbiguousPosition, 1);
      expect(analyzeSeedText('abandon act ').pendingAmbiguousPosition, isNull);
    });

    test('finds glued words and unique splits', () {
      final a = analyzeSeedText('abandonabout zoo');
      expect(a.gluedPositions, [0]);
      expect(a.uniqueSplits[0], ['abandon', 'about']);
      expect(segmentGluedWords('xyzzyxyzzy'), isEmpty);
    });

    test('non-ASCII letters, but not invisible separators', () {
      expect(analyzeSeedText('abóut').hasNonAsciiLetters, isTrue);
      expect(analyzeSeedText('аbout').hasNonAsciiLetters, isTrue);
      expect(analyzeSeedText('abandon about​').hasNonAsciiLetters, isFalse);
    });

    test('replaceSeedWord canonicalises and keeps typing position', () {
      expect(
        replaceSeedWord(['abandon', 'ab'], 1, 'about',
            hadTrailingSeparator: false),
        'abandon about ',
      );
      expect(
        replaceSeedWord(['ab', 'zoo'], 0, 'about', hadTrailingSeparator: false),
        'about zoo',
      );
    });

    test('pasted line breaks become spaces', () {
      expect(normalizePastedSeed('abandon\nabout\r\nzoo\tzoo'),
          'abandon about zoo zoo');
    });
  });

  group('hints', () {
    test('nickname warnings', () {
      expect(NicknameWarnings.of('visa').any, isFalse);
      expect(NicknameWarnings.of('visa ').edgeWhitespace, isTrue);
      expect(NicknameWarnings.of('​visa').edgeWhitespace, isTrue);
      expect(NicknameWarnings.of('café').nonAscii, isTrue);
      final long = NicknameWarnings.of('é' * 10);
      expect(long.utf8Bytes, 20);
      expect(long.tooLong, isTrue);
      expect(NicknameWarnings.of('a' * 19).tooLong, isFalse);
    });

    test('display helpers', () {
      expect(withVisibleSpaces(' a b'), '␣a␣b');
      expect(chunked('abcdefghij', 4), ['abcd', 'efgh', 'ij']);
      expect(clampPin24Length(0), 1);
      expect(clampPin24Length(99), 12);
      expect(pin24MaskOf(kPin24DefaultCharsets), 0x07);
      expect(pin24MaskOf(Pin24Charset.values), 0xFF);
    });
  });

  group('PinSeedCache', () {
    test('lookup by phrase+passphrase, copies out, zeroes on wipe', () {
      final cache = PinSeedCache();
      addTearDown(cache.dispose);
      final key = PinSeedCache.keyFor('abandon about', '');
      final seed = Uint8List.fromList(List.generate(64, (i) => i + 1));
      cache.store(key, seed, wordCount: 12);

      final hit = cache.lookup(PinSeedCache.keyFor('abandon about', ''))!;
      expect(hit, seed);
      expect(identical(hit, seed), isFalse);
      expect(cache.lookup(PinSeedCache.keyFor('abandon about', ' ')), isNull);
      expect(cache.lookup(PinSeedCache.keyFor('abandon abou', 't')), isNull);
      expect('$cache', isNot(contains('1, 2')));

      cache.wipe();
      expect(cache.hasSeed, isFalse);
      expect(seed.every((b) => b == 0), isTrue);
      expect(key.every((b) => b == 0), isTrue);
    });

    test('replacing the seed zeroes the old one', () {
      final cache = PinSeedCache();
      addTearDown(cache.dispose);
      final first = Uint8List.fromList(List.filled(64, 7));
      cache.store(PinSeedCache.keyFor('a', ''), first, wordCount: 12);
      cache.store(PinSeedCache.keyFor('b', ''), Uint8List(64), wordCount: 24);
      expect(first.every((b) => b == 0), isTrue);
      expect(cache.wordCount, 24);
    });
  });
}
