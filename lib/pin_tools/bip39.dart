/// BIP39 (English) helpers for the PIN tools.
///
/// Two layers, both ported from personal-crypto-tools:
///
/// * the seed-entry UI of the Streamlit "PIN 24" page (`pin24_ui.py`):
///   [parseSeedWords], [validateWords], [targetWordCount],
///   [suggestionsForPrefix];
/// * the python-mnemonic checksum used by the backend (`Mnemonic.check`):
///   [bip39ChecksumValid].
///
/// Pure Dart (no Flutter imports): safe to use from `Isolate.run` and plain
/// `dart test`.
library;

import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'bip39_english.dart';

/// Mnemonic lengths BIP39 allows, in words (`SUPPORTED_WORD_COUNTS`).
const List<int> kSupportedWordCounts = [12, 15, 18, 21, 24];

/// Number of completions the source UI lists for a partial word.
const int kDefaultSuggestionLimit = 6;

/// Word → 11-bit index. A lazily initialised, never-mutated top-level final.
final Map<String, int> _wordIndex = {
  for (var i = 0; i < bip39English.length; i++) bip39English[i]: i,
};

/// Every non-empty proper prefix of every word (`a`, `ab`, …, `abando`, …;
/// about 7.5k entries). A non-word is a prefix of some word exactly when it
/// is in this set, and a word is a prefix of another word exactly when it is
/// in it too. Lazily initialised, never mutated.
final Set<String> _properPrefixes = {
  for (final w in bip39English)
    for (var n = 1; n < w.length; n++) w.substring(0, n),
};

/// Any run of characters that is not an ASCII lowercase letter
/// (`_WORD_SEP_RE` in `pin24_ui.py`).
final RegExp _wordSeparator = RegExp('[^a-z]+');

/// Index (0..2047) of [word] in the English wordlist, or null.
int? bip39WordIndex(String word) => _wordIndex[word];

/// Whether [word] is exactly one of the 2048 English words.
bool isBip39Word(String word) => _wordIndex.containsKey(word);

/// Python's `str.lower()`, as far as it differs from Dart in a way that
/// matters for BIP39.
///
/// Python applies the unconditional full case mapping U+0130 (İ) →
/// `i` + U+0307, while Dart's `toLowerCase()` yields a bare `i`. Without this
/// fix `İdle` would parse as the valid word `idle` here but as `i` + `dle`
/// (UI) or an invalid word (backend) in Python.
///
/// Parity is guaranteed only on the projection BIP39 depends on: which
/// characters are (or NFKD-fold to) ASCII `a`–`z`, and where everything else
/// sits. Word splitting, word states, validity and the derived seed are
/// therefore identical to Python. The full string is not: Dart never picks
/// the Greek final sigma (Python: `ΟΔΟΣ` → `οδος`, Dart: `οδοσ`), and its
/// case tables predate Unicode 16 for 437 non-Latin letters (e.g. Georgian
/// Mtavruli U+1C90, Adlam U+1E900, Greek U+037F). None of those lowercase or
/// NFKD-fold into ASCII `a`–`z`; the test suite checks this exhaustively over
/// all code points. Never display the result as Python's value.
String pythonLower(String s) {
  if (!s.contains('\u0130')) return s.toLowerCase();
  return s.split('\u0130').map((part) => part.toLowerCase()).join('i\u0307');
}

// ─────────────────────────────────────────────────────────────────────────────
// Seed-entry parser (pin24_ui.py `_parse_seed_words`)
// ─────────────────────────────────────────────────────────────────────────────

/// Classification of one typed word.
enum Bip39WordState {
  /// Exactly one of the 2048 English words.
  valid,

  /// Not a word, but the prefix of at least one word (still typing).
  partial,

  /// Neither a word nor a prefix of one.
  invalid,
}

/// Result of [parseSeedWords]: the recovered words and their states.
class ParsedSeed {
  const ParsedSeed(this.words, this.states);

  /// Lowercase `a`–`z` words in input order.
  final List<String> words;

  /// `states[i]` classifies `words[i]`.
  final List<Bip39WordState> states;

  /// The phrase that is validated and derived from (`" ".join(words)`).
  String get canonical => words.join(' ');

  /// 0-based positions of [Bip39WordState.invalid] words (Python `bad`).
  List<int> get invalidPositions => _positions(Bip39WordState.invalid);

  /// 0-based positions of [Bip39WordState.partial] words (Python `partial`).
  List<int> get partialPositions => _positions(Bip39WordState.partial);

  List<int> _positions(Bip39WordState state) => [
        for (var i = 0; i < states.length; i++)
          if (states[i] == state) i,
      ];
}

/// Splits pasted or typed text into BIP39 words, exactly like the source UI.
///
/// The input is lowercased (Python semantics, see [pythonLower]) and split
/// on every run of non-`a`–`z` characters, so spaces, newlines, dashes,
/// commas, numbered lists, NBSP, zero-width characters and a BOM all work as
/// separators. Accented or non-Latin letters are separators too: `abóut`
/// becomes `ab` + `ut`, and a Cyrillic `а` is dropped.
///
/// Unlike `normalizeSeedPhrase` in `ledger_pin24.dart` this does not apply
/// NFKD, so fullwidth letters are dropped here rather than folded.
ParsedSeed parseSeedWords(String input) {
  final words = pythonLower(input)
      .split(_wordSeparator)
      .where((w) => w.isNotEmpty)
      .toList(growable: false);
  final states = [for (final w in words) _classify(w)];
  return ParsedSeed(
    List.unmodifiable(words),
    List.unmodifiable(states),
  );
}

/// O(1): a non-word is `partial` exactly when some word starts with it,
/// i.e. when it is a proper prefix of that word.
Bip39WordState _classify(String word) {
  if (isBip39Word(word)) return Bip39WordState.valid;
  if (_properPrefixes.contains(word)) return Bip39WordState.partial;
  return Bip39WordState.invalid;
}

/// Number of word cells to draw for [typed] words (`_target_word_count`).
///
/// 0 → 24 (the Ledger default); otherwise the smallest supported count that
/// is ≥ [typed]; more than 24 words still shows 24 cells.
int targetWordCount(int typed) {
  if (typed == 0) return 24;
  for (final n in kSupportedWordCounts) {
    if (typed <= n) return n;
  }
  return kSupportedWordCounts.last;
}

// ─────────────────────────────────────────────────────────────────────────────
// Validation (pin24_ui.py `_validate_full_phrase`)
// ─────────────────────────────────────────────────────────────────────────────

/// Outcome of [validateWords], in the order the checks run.
enum Bip39Status { empty, wrongCount, notInWordlist, badChecksum, ok }

/// Status of a parsed phrase plus the word count the messages refer to.
class Bip39Validation {
  const Bip39Validation(this.status, this.wordCount);

  final Bip39Status status;
  final int wordCount;

  bool get isValid => status == Bip39Status.ok;

  /// The source UI's English status line, verbatim.
  String get message => switch (status) {
        Bip39Status.empty => 'Enter the seed phrase below.',
        Bip39Status.wrongCount => 'Got $wordCount words; BIP39 requires one of '
            '${kSupportedWordCounts.join(', ')}.',
        Bip39Status.notInWordlist =>
          'Some words are not in the BIP39 English wordlist.',
        Bip39Status.badChecksum =>
          'Phrase is the right length but the BIP39 checksum fails.',
        Bip39Status.ok => '$wordCount words, BIP39 checksum valid.',
      };
}

/// Validates parsed words: empty → count → wordlist → checksum.
Bip39Validation validateWords(List<String> words) {
  final n = words.length;
  if (n == 0) return const Bip39Validation(Bip39Status.empty, 0);
  if (!kSupportedWordCounts.contains(n)) {
    return Bip39Validation(Bip39Status.wrongCount, n);
  }
  if (!words.every(isBip39Word)) {
    return Bip39Validation(Bip39Status.notInWordlist, n);
  }
  if (!bip39ChecksumValid(words)) {
    return Bip39Validation(Bip39Status.badChecksum, n);
  }
  return Bip39Validation(Bip39Status.ok, n);
}

/// python-mnemonic `Mnemonic("english").check` on an already-split phrase.
///
/// True only if the count is supported, every entry is exactly a wordlist
/// word (no trimming, case folding, prefix expansion or normalisation) and
/// the trailing `n/33` bits equal the leading bits of SHA-256(entropy).
bool bip39ChecksumValid(List<String> words) {
  final n = words.length;
  if (!kSupportedWordCounts.contains(n)) return false;
  final totalBits = n * 11;
  final checksumBits = totalBits ~/ 33;
  final entropyBytes = (totalBits - checksumBits) ~/ 8;
  // entropy || checksum, packed big-endian; checksum (4..8 bits) fits in the
  // byte right after the entropy.
  final packed = Uint8List(entropyBytes + 1);
  var bitPos = 0;
  for (final word in words) {
    final index = _wordIndex[word];
    if (index == null) {
      packed.fillRange(0, packed.length, 0);
      return false;
    }
    for (var b = 10; b >= 0; b--) {
      if ((index >> b) & 1 == 1) {
        packed[bitPos >> 3] |= 0x80 >> (bitPos & 7);
      }
      bitPos++;
    }
  }
  final entropy = Uint8List.sublistView(packed, 0, entropyBytes);
  final hash = SHA256Digest().process(entropy);
  final shift = 8 - checksumBits;
  final ok = (hash[0] >> shift) == (packed[entropyBytes] >> shift);
  packed.fillRange(0, packed.length, 0);
  hash.fillRange(0, hash.length, 0);
  return ok;
}

// ─────────────────────────────────────────────────────────────────────────────
// Completion helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Wordlist words starting with [prefix], in wordlist order, cut like the
/// Python slice `matches[:limit]` (a negative [limit] drops that many from the
/// end). An empty prefix yields nothing.
///
/// The wordlist is strictly sorted, so the matches are one contiguous run
/// that starts at the first word `>= prefix` (binary search).
List<String> suggestionsForPrefix(
  String prefix, {
  int limit = kDefaultSuggestionLimit,
}) {
  if (prefix.isEmpty) return const [];
  var lo = 0;
  var hi = bip39English.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (bip39English[mid].compareTo(prefix) < 0) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  var end = lo;
  while (end < bip39English.length && bip39English[end].startsWith(prefix)) {
    end++;
  }
  final n = end - lo;
  final take =
      limit >= 0 ? (limit < n ? limit : n) : (n + limit > 0 ? n + limit : 0);
  return List.unmodifiable(bip39English.sublist(lo, lo + take));
}

/// True for the 49 words that are also a prefix of another word (`act` →
/// `action`, `art` → `artist`, …). Every other word is fixed by its first
/// four letters, so these are the only ones that must not be auto-accepted
/// as soon as they are typed.
bool isAmbiguousPrefixWord(String word) =>
    isBip39Word(word) && _properPrefixes.contains(word);
