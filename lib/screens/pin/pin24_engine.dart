/// Pure-Dart glue between the PIN 24 screen and the core in
/// `lib/pin_tools/`: the isolate request/response, error-code mapping and the
/// seed-entry helpers (auto-accept, glued words, non-ASCII detection).
///
/// No Flutter imports, so everything here runs inside `Isolate.run` and in
/// plain unit tests. Nothing here logs, prints or throws with user input in
/// the message.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../pin_tools/bip39.dart';
import '../../pin_tools/bip39_english.dart';
import '../../pin_tools/ledger_pin24.dart';
import '../../pin_tools/python_text.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Options
// ─────────────────────────────────────────────────────────────────────────────

/// Output mode: a numeric PIN (first N digits of the NUMBERS+SEPARATORS
/// output) or the full 20-character password for the chosen charsets.
enum Pin24Mode { pin, password }

/// The five charset toggles of the Ledger Passwords app, in device order.
enum Pin24Charset {
  upper(kUppercase),
  lower(kLowercase),
  digits(kNumbers),
  separators(kBars),
  specials(kExtSymbols);

  const Pin24Charset(this.mask);

  /// Bits of the core `setMask` this toggle enables.
  final int mask;
}

/// Toggles that are on after every tap on "Password" (the device default).
const Set<Pin24Charset> kPin24DefaultCharsets = {
  Pin24Charset.upper,
  Pin24Charset.lower,
  Pin24Charset.digits,
};

/// Quick-pick PIN lengths.
const List<int> kPin24QuickLengths = [4, 6, 8, 12];
const int kPin24DefaultLength = 4;
const int kPin24MinLength = 1;

/// Longest PIN offered: above 12 the 20-character output would often not have
/// enough digits (measured: 3.3 % of nicknames are zero-padded at 12).
const int kPin24MaxLength = kPinMaxLength;

/// Clamps a stored or typed length into 1…12.
int clampPin24Length(int length) =>
    length.clamp(kPin24MinLength, kPin24MaxLength);

/// Core `setMask` for a set of toggles (0 when none is on).
int pin24MaskOf(Iterable<Pin24Charset> charsets) =>
    charsets.fold(0, (mask, c) => mask | c.mask);

/// The toggles that give exactly [mask], or `null` when the five toggles
/// cannot express it: the device groups MINUS, UNDERLINE and SPACE into
/// "separators" and SPECIAL and BRACKETS into "specials", so a mask with
/// only part of a group (a backup entry with just `MINUS`, say) needs the
/// raw mask. 0 gives the empty set.
Set<Pin24Charset>? pin24CharsetsForMask(int mask) {
  if (mask < 0 || mask > kAllSets) return null;
  final out = <Pin24Charset>{};
  for (final c in Pin24Charset.values) {
    final bits = mask & c.mask;
    if (bits == c.mask) {
      out.add(c);
    } else if (bits != 0) {
      return null;
    }
  }
  return out;
}

// ─────────────────────────────────────────────────────────────────────────────
// Isolate request / response
// ─────────────────────────────────────────────────────────────────────────────

/// Everything one derivation needs. Only sendable fields (strings, ints,
/// [Uint8List]), so it crosses into `Isolate.run`.
class Pin24Request {
  const Pin24Request({
    required this.nickname,
    required this.mode,
    required this.length,
    required this.setMask,
    this.canonicalPhrase,
    this.passphrase = '',
    this.cachedSeed,
  }) : assert((canonicalPhrase == null) != (cachedSeed == null));

  /// Validated phrase (`" ".join(words)`), when no cached seed matches.
  final String? canonicalPhrase;
  final String passphrase;

  /// A private copy of the cached 64-byte seed; the compute zeroes it.
  final Uint8List? cachedSeed;
  final String nickname;
  final Pin24Mode mode;
  final int length;
  final int setMask;

  @override
  String toString() => 'Pin24Request(<redacted>)';
}

/// Result of [pin24Compute]. Holds strings (which cannot be wiped) and, when
/// the seed was derived now, the fresh seed for the caller's cache.
class Pin24Response {
  const Pin24Response({
    this.pin,
    this.fullPassword,
    this.digitsInOutput = 0,
    this.paddedZeros = 0,
    this.password,
    this.errorCode,
    this.freshSeed,
  });

  /// PIN mode: exactly `length` digits.
  final String? pin;

  /// PIN mode: the 20-character NUMBERS+SEPARATORS output.
  final String? fullPassword;
  final int digitsInOutput;
  final int paddedZeros;

  /// Password mode: the 20-character password.
  final String? password;

  /// A [Pin24Exception.code], or [pin24UnexpectedError]. Never a message.
  final String? errorCode;

  /// The 64-byte seed if it was derived by this call; the receiver owns it
  /// (cache it or zero it).
  final Uint8List? freshSeed;

  bool get isError => errorCode != null;

  @override
  String toString() => 'Pin24Response(<redacted>)';
}

/// Error code for anything that is not a [Pin24Exception].
const String pin24UnexpectedError = 'UNEXPECTED';

/// Runs one derivation. Never throws: every failure becomes
/// [Pin24Response.errorCode], so no exception (whose text could quote the
/// input) reaches an error handler or crosses the isolate boundary.
///
/// Zeroes [Pin24Request.cachedSeed] before returning.
Pin24Response pin24Compute(Pin24Request request) {
  Uint8List? fresh;
  try {
    final Uint8List seed;
    if (request.cachedSeed != null) {
      seed = request.cachedSeed!;
    } else {
      fresh = bip39ToSeed(
        request.canonicalPhrase!,
        passphrase: request.passphrase,
      );
      seed = fresh;
    }
    if (request.mode == Pin24Mode.password) {
      final password = derivePassword(
        bip39Seed: seed,
        nickname: request.nickname,
        setMask: request.setMask,
      );
      return Pin24Response(password: password, freshSeed: fresh);
    }
    final d = derivePinDetailed(
      bip39Seed: seed,
      nickname: request.nickname,
      length: request.length,
    );
    return Pin24Response(
      pin: d.pin,
      fullPassword: d.fullPassword,
      digitsInOutput: d.digitsInOutput,
      paddedZeros: d.paddedZeros,
      freshSeed: fresh,
    );
  } on Pin24Exception catch (e) {
    fresh?.fillRange(0, fresh.length, 0);
    return Pin24Response(errorCode: e.code);
  } catch (_) {
    fresh?.fillRange(0, fresh.length, 0);
    return const Pin24Response(errorCode: pin24UnexpectedError);
  } finally {
    final cached = request.cachedSeed;
    cached?.fillRange(0, cached.length, 0);
  }
}

/// The seed alone (PBKDF2 of a validated phrase + passphrase), so the section
/// can cache it as soon as the phrase is valid — before any nickname is typed
/// (the YubiKey tool's Ledger source needs only the seed).
class Pin24SeedRequest {
  const Pin24SeedRequest({
    required this.canonicalPhrase,
    this.passphrase = '',
  });

  final String canonicalPhrase;
  final String passphrase;

  @override
  String toString() => 'Pin24SeedRequest(<redacted>)';
}

/// Derives the 64-byte seed of [request] into [Pin24Response.freshSeed].
/// Never throws: failures become [Pin24Response.errorCode].
Pin24Response pin24SeedCompute(Pin24SeedRequest request) {
  try {
    return Pin24Response(
      freshSeed: bip39ToSeed(
        request.canonicalPhrase,
        passphrase: request.passphrase,
      ),
    );
  } on Pin24Exception catch (e) {
    return Pin24Response(errorCode: e.code);
  } catch (_) {
    return const Pin24Response(errorCode: pin24UnexpectedError);
  }
}

/// Sends [request] through [runner] (top-level: the closure captures only
/// [request]).
Future<Pin24Response> runPin24Seed(
  PinComputeRunner runner,
  Pin24SeedRequest request,
) =>
    runner(() => pin24SeedCompute(request));

/// Runs a computation somewhere else: `Isolate.run` in the app, inline in
/// widget tests (whose fake clock cannot drive real isolates).
typedef PinComputeRunner = Future<R> Function<R>(
  FutureOr<R> Function() computation,
);

/// Sends [request] through [runner]. A top-level function so that the
/// closure handed to the isolate captures nothing but [request].
Future<Pin24Response> runPin24(PinComputeRunner runner, Pin24Request request) =>
    runner(() => pin24Compute(request));

/// What the UI should say for a [Pin24Response.errorCode].
enum Pin24ErrorKind {
  bip39Invalid,
  passphraseNotUtf8,
  nicknameEmpty,
  nicknameNotUtf8,
  bip32Invalid,
  generic,
}

Pin24ErrorKind pin24ErrorKind(String code) => switch (code) {
      Pin24Exception.bip39Invalid => Pin24ErrorKind.bip39Invalid,
      Pin24Exception.passphraseNotUtf8 => Pin24ErrorKind.passphraseNotUtf8,
      Pin24Exception.nicknameEmpty => Pin24ErrorKind.nicknameEmpty,
      Pin24Exception.nicknameNotUtf8 => Pin24ErrorKind.nicknameNotUtf8,
      Pin24Exception.bip32Invalid => Pin24ErrorKind.bip32Invalid,
      _ => Pin24ErrorKind.generic,
    };

// ─────────────────────────────────────────────────────────────────────────────
// Seed entry
// ─────────────────────────────────────────────────────────────────────────────

/// Everything the seed card shows about the typed text. Built on every
/// keystroke (cheap: at most a few thousand prefix checks).
class SeedTextAnalysis {
  SeedTextAnalysis._({
    required this.parsed,
    required this.validation,
    required this.hasText,
    required this.endsInsideWord,
    required this.hasNonAsciiLetters,
    required this.gluedPositions,
    required this.uniqueSplits,
    required this.pendingAmbiguousPosition,
  });

  final ParsedSeed parsed;
  final Bip39Validation validation;

  /// The field is not empty (it may still hold no word, e.g. only digits).
  final bool hasText;

  /// The text ends in a letter, i.e. the last word may still be typed.
  final bool endsInsideWord;

  /// Letters outside ASCII (accents, Cyrillic look-alikes, fullwidth): the
  /// parser treats them as separators, which the user should know about.
  final bool hasNonAsciiLetters;

  /// 0-based positions of invalid words that are two or more BIP39 words
  /// run together (line breaks are dropped when pasting into a single-line
  /// field).
  final List<int> gluedPositions;

  /// For glued words with exactly one way to split them: position → words.
  final Map<int, List<String>> uniqueSplits;

  /// 0-based position of the last word when it is a complete word that also
  /// starts longer words (`act` → `action`, …) and is still being typed;
  /// such a word needs an explicit confirmation.
  final int? pendingAmbiguousPosition;

  List<String> get words => parsed.words;
  List<Bip39WordState> get states => parsed.states;
  int get target => targetWordCount(parsed.words.length);
}

final RegExp _letterOrMark = RegExp(r'[\p{L}\p{M}]', unicode: true);

bool _isAsciiLetter(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

/// Analyses the raw seed-field text.
SeedTextAnalysis analyzeSeedText(String text) {
  final parsed = parseSeedWords(text);
  final validation = validateWords(parsed.words);
  final endsInsideWord =
      text.isNotEmpty && _isAsciiLetter(text.codeUnitAt(text.length - 1));

  var nonAscii = false;
  for (final rune in text.runes) {
    if (rune > 0x7F && _letterOrMark.hasMatch(String.fromCharCode(rune))) {
      nonAscii = true;
      break;
    }
  }

  final glued = <int>[];
  final splits = <int, List<String>>{};
  for (final i in parsed.invalidPositions) {
    final found = segmentGluedWords(parsed.words[i]);
    if (found.isEmpty) continue;
    glued.add(i);
    if (found.length == 1) splits[i] = found.single;
  }

  int? ambiguous;
  if (endsInsideWord && parsed.words.isNotEmpty) {
    final last = parsed.words.length - 1;
    if (parsed.states[last] == Bip39WordState.valid &&
        isAmbiguousPrefixWord(parsed.words[last])) {
      ambiguous = last;
    }
  }

  return SeedTextAnalysis._(
    parsed: parsed,
    validation: validation,
    hasText: text.isNotEmpty,
    endsInsideWord: endsInsideWord,
    hasNonAsciiLetters: nonAscii,
    gluedPositions: List.unmodifiable(glued),
    uniqueSplits: Map.unmodifiable(splits),
    pendingAmbiguousPosition: ambiguous,
  );
}

/// Ways to cut [glued] into two or more BIP39 words (at most [limit]).
/// Empty when there is none. Used for words that lost their separator.
List<List<String>> segmentGluedWords(String glued, {int limit = 2}) {
  // BIP39 English words are 3–8 letters; two of them need at least 6.
  if (glued.length < 6 || glued.length > 8 * 24) return const [];
  final memo = <int, List<List<String>>>{};
  List<List<String>> from(int start) {
    if (start == glued.length) return const [<String>[]];
    final cached = memo[start];
    if (cached != null) return cached;
    final out = <List<String>>[];
    for (var len = 3; len <= 8 && start + len <= glued.length; len++) {
      final word = glued.substring(start, start + len);
      if (!isBip39Word(word)) continue;
      for (final rest in from(start + len)) {
        out.add([word, ...rest]);
        if (out.length >= limit) break;
      }
      if (out.length >= limit) break;
    }
    memo[start] = out;
    return out;
  }

  return [
    for (final s in from(0))
      if (s.length >= 2) s,
  ];
}

/// The seed text with the word at [index] replaced by [replacement] (which
/// may hold several space-separated words). The result is canonical (single
/// spaces); a trailing space is kept, or added when the last word was
/// replaced, so typing continues with the next word.
String replaceSeedWord(
  List<String> words,
  int index,
  String replacement, {
  required bool hadTrailingSeparator,
}) {
  final next = [...words]..[index] = replacement;
  final trailing = hadTrailingSeparator || index == words.length - 1;
  return next.join(' ') + (trailing ? ' ' : '');
}

/// Auto-complete on a separator: if [newText] is [oldText] plus one typed
/// separator (space, comma, dash, line break…) right after a word of at
/// least 4 letters that is not itself a wordlist word and that exactly one
/// wordlist word starts with, returns the text with that word completed
/// (the separator kept). Otherwise `null`.
///
/// Every BIP39 English word is fixed by its first four letters, so typing
/// `aban` + space is enough. Nothing is completed while a word is still
/// being typed, so typing whole words key by key — as they are written on
/// the recovery sheet — always ends with exactly what was typed. A word
/// that is complete but also starts longer words (`act`) is never extended.
String? autoAcceptSeedEdit(String oldText, String newText) {
  if (newText.length != oldText.length + 1 || !newText.startsWith(oldText)) {
    return null;
  }
  final separator = newText.codeUnitAt(newText.length - 1);
  if (_isAsciiLetter(separator) || separator > 0x7F) return null;
  var start = oldText.length;
  while (start > 0 && _isAsciiLetter(oldText.codeUnitAt(start - 1))) {
    start--;
  }
  final prefix = oldText.substring(start).toLowerCase();
  if (prefix.length < 4 || isBip39Word(prefix)) return null;
  String? only;
  for (final w in bip39English) {
    if (!w.startsWith(prefix)) continue;
    if (only != null) return null;
    only = w;
  }
  if (only == null) return null;
  return '${oldText.substring(0, start)}$only'
      '${String.fromCharCode(separator)}';
}

/// Normalises pasted text for a single-line field: Flutter drops `\n` in
/// single-line fields, which would glue one-word-per-line lists together.
String normalizePastedSeed(String text) =>
    text.replaceAll(RegExp(r'[\r\n\t\v\f  ]+'), ' ');

// ─────────────────────────────────────────────────────────────────────────────
// Nickname / passphrase hints
// ─────────────────────────────────────────────────────────────────────────────

/// Longest nickname (UTF-8 bytes) the Ledger Passwords app stores.
const int kLedgerMaxNicknameBytes = 19;

const Set<int> _invisibleEdge = {0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF};

/// Whether [s] starts or ends with whitespace (Python's set) or an invisible
/// format character; those are part of the value and change the result.
bool hasEdgeWhitespace(String s) {
  if (s.isEmpty) return false;
  final runes = s.runes;
  bool edge(int c) => isPythonSpace(c) || _invisibleEdge.contains(c);
  return edge(runes.first) || edge(runes.last);
}

/// Soft warnings for a nickname; none of them blocks derivation.
class NicknameWarnings {
  const NicknameWarnings({
    required this.edgeWhitespace,
    required this.nonAscii,
    required this.utf8Bytes,
  });

  factory NicknameWarnings.of(String nickname) {
    var nonAscii = false;
    for (final c in nickname.codeUnits) {
      if (c > 0x7F) {
        nonAscii = true;
        break;
      }
    }
    // A lone surrogate is reported by the derivation error instead.
    final bytes = hasLoneSurrogate(nickname) ? 0 : utf8.encode(nickname).length;
    return NicknameWarnings(
      edgeWhitespace: hasEdgeWhitespace(nickname),
      nonAscii: nonAscii,
      utf8Bytes: bytes,
    );
  }

  final bool edgeWhitespace;
  final bool nonAscii;
  final int utf8Bytes;

  bool get tooLong => utf8Bytes > kLedgerMaxNicknameBytes;
  bool get any => edgeWhitespace || nonAscii || tooLong;
}

// ─────────────────────────────────────────────────────────────────────────────
// Display
// ─────────────────────────────────────────────────────────────────────────────

/// Shows spaces as `␣` so a leading/trailing/double space is visible.
String withVisibleSpaces(String s) => s.replaceAll(' ', '␣');

/// Splits [s] into chunks of [size] characters (code units; outputs are
/// ASCII).
List<String> chunked(String s, int size) => [
      for (var i = 0; i < s.length; i += size)
        s.substring(i, i + size > s.length ? s.length : i + size),
    ];
