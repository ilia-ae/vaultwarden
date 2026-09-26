import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/pin_tools/bip39.dart';
import 'package:vault_approver/screens/pin/pin24_engine.dart';
import 'package:vault_approver/screens/pin/pin_session.dart';

void main() {
  group('auto-accept', () {
    test('completes a unique 4-letter prefix typed at the end', () {
      expect(autoAcceptSeedEdit('abandon aba', 'abandon aban'),
          'abandon abandon ');
      expect(autoAcceptSeedEdit('zo', 'zoo'), isNull, reason: '< 4 letters');
      expect(autoAcceptSeedEdit('abl', 'able'), 'able ');
      expect(autoAcceptSeedEdit('ACTI'.substring(0, 3), 'ACTI'), 'action ');
    });

    test('never fires on pastes, edits in the middle, or no match', () {
      expect(autoAcceptSeedEdit('', 'aban'), isNull);
      expect(autoAcceptSeedEdit('aban x', 'abanx x'), isNull);
      expect(autoAcceptSeedEdit('xyz', 'xyzz'), isNull);
    });

    test('the 49 prefix words are never auto-accepted', () {
      for (final w in ['act', 'art', 'you', 'win']) {
        expect(isAmbiguousPrefixWord(w), isTrue);
        expect(autoAcceptSeedEdit(w.substring(0, 2), w), isNull);
      }
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
