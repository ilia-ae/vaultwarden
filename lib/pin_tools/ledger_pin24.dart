/// Bit-for-bit port of personal-crypto-tools `crypto_tools/pin24.py`: the
/// recovery-only reimplementation of the LedgerHQ/app-passwords derivation
/// (what a Ledger "Passwords" app would type for a nickname).
///
/// ```text
/// nickname (UTF-8) ─► SHA-256 ─► path m/0x80505744'/h[0..3]'/…/h[28..31]'
/// ─► BIP32 hardened CKD on secp256k1 from HMAC-SHA512("Bitcoin seed", seed)
/// ─► SHA-256(leafKey ‖ leafChain) = 32-byte entropy
/// ─► mbedtls CTR_DRBG-AES-256 (entropy length 32, no nonce/personalisation)
/// ─► per-charset minimum samples, union fill, Fisher-Yates shuffle
/// ```
///
/// Pure Dart (no Flutter imports), top-level functions only. Run it through
/// `Isolate.run`: PBKDF2 (2048 × HMAC-SHA512) dominates the cost, and an
/// isolate's heap, with whatever this library could not wipe, is released as
/// a whole when the isolate exits.
///
/// Memory hygiene, precisely:
///
/// * Zeroed before they are dropped (also on error paths): every byte buffer
///   this library allocates for secret material. That covers the UTF-8 phrase
///   and salt, PBKDF2's U/T/block buffers, the seed from a phrase, BIP32 keys
///   and chain codes, HMAC outputs, the entropy, the DRBG key, counter and
///   temporaries, `blockCipherDf` buffers and the password bytes.
/// * Scrubbed in place: HMAC key pads (the `HMac` is re-initialised with an
///   empty key, which overwrites `key ^ ipad`, `key ^ opad` and the SHA-512
///   state/W buffer) and AES round-key schedules ([WipeableAesEngine]).
/// * Not wipeable; stays until garbage collection: Dart `String`s (phrase,
///   passphrase, nickname and the returned password or PIN), the code-point
///   lists `unorm_dart` builds during NFKD, and the `Register64` temporaries
///   inside pointycastle's SHA-2.
///
/// Caller-owned inputs such as a raw seed are never modified.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'bip39.dart';
import 'python_text.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Constants (must match app-passwords exactly)
// ─────────────────────────────────────────────────────────────────────────────

/// Charset bit flags (`src/password_generation.h`).
const int kUppercase = 0x01;
const int kLowercase = 0x02;
const int kNumbers = 0x04;
const int kMinus = 0x08;
const int kUnderline = 0x10;
const int kSpace = 0x20;
const int kSpecial = 0x40;
const int kBrackets = 0x80;
const int kAllSets = 0xFF;

/// The device's "Use separators" toggle: MINUS | UNDERLINE | SPACE.
const int kBars = 0x38;

/// The device's "Use special characters" toggle: SPECIAL | BRACKETS.
const int kExtSymbols = 0xC0;

/// NUMBERS | BARS: the default mask and the one PINs are read from.
const int kPinMask = 0x3C;

/// Minimum characters per charset, indexed by bit position
/// (`src/password_typing.h` DEFAULT_MIN_SET; note SPACE = 1).
const List<int> kDefaultMinSet = [1, 1, 1, 0, 0, 1, 0, 0];

/// `password.h::PASSWORD_MAX_SIZE`: every device password is 20 characters.
const int kPasswordMaxSize = 20;

/// Longest PIN the UI offers (the backend itself has no upper bound).
const int kPinMaxLength = 12;

/// First path element: hardened 0x505744 ("PWD").
const int kDerivePasswordPath = 0x80505744;

/// Charsets in bit order (`src/password_generation.c` SETS[]). The SPECIAL
/// order is not ASCII-sorted and is load-bearing: indices map to characters.
const List<String> kCharsets = [
  'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
  'abcdefghijklmnopqrstuvwxyz',
  '0123456789',
  '-',
  '_',
  ' ',
  r'''"#$%&'*+,./:;=?!@\^`|~''',
  '[]{}()<>',
];

const int _numSets = 8;
const int _keySize = 32;
const int _blockSize = 16;
const int _seedLen = _keySize + _blockSize; // 48
const int _maxSeedInput = 384;

/// secp256k1 group order n, big-endian, with a leading zero byte so it can be
/// compared against a 33-byte sum.
final Uint8List _secp256k1N33 = _hexToBytes(
  '00fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141',
);

final Uint8List _bitcoinSeedKey = Uint8List.fromList(
  ascii.encode('Bitcoin seed'),
);

// ─────────────────────────────────────────────────────────────────────────────
// Errors
// ─────────────────────────────────────────────────────────────────────────────

const String _bip39InvalidMessage =
    'Seed phrase failed BIP39 validation (wordlist match + checksum). '
    'Double-check spelling and word order.';

/// Every error the Python module raises, as a stable [code] plus the exact
/// Python message.
///
/// [message] is Python-parity text for tests and diagnostics, not UI copy.
/// For [passphraseNotUtf8] and [nicknameNotUtf8] it quotes an input
/// character and its position ([messageQuotesInput]), so it must never be
/// displayed or logged: the UI maps [code] to a fixed localized string, and
/// [toString] omits the message for those codes.
class Pin24Exception implements Exception {
  const Pin24Exception(this.code, this.message);

  static const String exactlyOneSeedSource = 'EXACTLY_ONE_SEED_SOURCE';
  static const String bip39Invalid = 'BIP39_INVALID';

  /// A lone UTF-16 surrogate in the BIP39 passphrase. Python raises
  /// UnicodeEncodeError from `mnemonic.to_seed`; Dart's `utf8.encode` would
  /// silently substitute U+FFFD and derive a different seed.
  static const String passphraseNotUtf8 = 'PASSPHRASE_NOT_UTF8';
  static const String seedLength = 'SEED_LENGTH';
  static const String nicknameEmpty = 'NICKNAME_EMPTY';

  /// A lone UTF-16 surrogate in the nickname (see [passphraseNotUtf8]).
  static const String nicknameNotUtf8 = 'NICKNAME_NOT_UTF8';
  static const String sizeNotPositive = 'SIZE_NOT_POSITIVE';
  static const String setMaskRange = 'SET_MASK_RANGE';
  static const String minFromSetLength = 'MIN_FROM_SET_LENGTH';
  static const String minExceedsSize = 'MIN_EXCEEDS_SIZE';

  /// `rng_u8_modulo` got a modulus outside 1..256; via the public API only
  /// `size > 256` reaches it.
  static const String moduloRange = 'MODULO_RANGE';
  static const String pinLengthNotPositive = 'PIN_LENGTH_NOT_POSITIVE';

  /// Invalid BIP32 input or a derivation hitting IL ≥ n / a zero key
  /// (≈ 2^-127, unreachable in practice).
  static const String bip32Invalid = 'BIP32_INVALID';

  final String code;

  /// The exact Python message; see the class docs before showing it.
  final String message;

  /// Whether [message] quotes part of the secret input (a character of the
  /// passphrase or nickname and its position).
  bool get messageQuotesInput =>
      code == passphraseNotUtf8 || code == nicknameNotUtf8;

  @override
  String toString() => messageQuotesInput
      ? 'Pin24Exception($code): [message withheld: it quotes the input]'
      : 'Pin24Exception($code): $message';
}

// ─────────────────────────────────────────────────────────────────────────────
// BIP39
// ─────────────────────────────────────────────────────────────────────────────

/// Python `" ".join(phrase.lower().split())`: lowercase, collapse runs of
/// Python whitespace (not Dart's `\s`: U+FEFF and U+200B are not separators,
/// U+001C–001F and U+0085 are) into single spaces, trim. No NFKD here.
///
/// Parity with Python is guaranteed on the projection that matters for
/// BIP39: which characters are ASCII `a`–`z` and where the word boundaries
/// are. BIP39 validity and the derived seed are therefore identical. The
/// full string can differ for other letters (see [pythonLower]): about 437
/// code points whose case mapping is newer than Dart's tables, and the Greek
/// final sigma (Python: `ΟΔΟΣ` → `οδος`, Dart: `οδοσ`). Do not present
/// this output as "Python's normalised phrase".
String normalizeSeedPhrase(String phrase) =>
    pythonSplit(pythonLower(phrase)).join(' ');

/// Code points that `unorm_dart` 0.3.2 normalises differently from Python
/// 3.14's `unicodedata` (Unicode 16.0.0), which is the reference for every
/// derived seed:
///
/// * U+1ACF–1ADD, U+1AE0–1AEB, U+10EFA–10EFB, U+1E6E3, U+1E6E6, U+1E6EE,
///   U+1E6EF, U+1E6F5: combining marks added in Unicode 17. `unorm_dart`
///   ships Unicode 17 data and reorders them (ccc ≠ 0); in Unicode 16 they
///   are unassigned starters (ccc 0) that nothing may move across.
/// * U+A7F1: Unicode 17 `<super> S`; unassigned (unchanged) in Unicode 16.
/// * U+D7A4: one past the last Hangul syllable. `unorm_dart` has an
///   off-by-one in `lib/src/uchar.dart` (`_SBase + _SCount < cp` should be
///   `<=`) and decomposes it to U+1113 U+1161; it is unassigned, so it must
///   stay as is. Reported upstream:
///   https://github.com/yshrsmz/unorm-dart/issues/84
///
/// All 36 are unassigned in Unicode 16: ccc 0 and no decomposition.
bool _isUnormDivergentCodePoint(int cp) =>
    (cp >= 0x1ACF && cp <= 0x1ADD) ||
    (cp >= 0x1AE0 && cp <= 0x1AEB) ||
    cp == 0xA7F1 ||
    cp == 0xD7A4 ||
    cp == 0x10EFA ||
    cp == 0x10EFB ||
    cp == 0x1E6E3 ||
    cp == 0x1E6E6 ||
    cp == 0x1E6EE ||
    cp == 0x1E6EF ||
    cp == 0x1E6F5;

/// Python 3.14 `unicodedata.normalize("NFKD", s)` (Unicode 16.0.0).
///
/// `unorm_dart` 0.3.2 agrees with Python on every code point except 36 (see
/// [_isUnormDivergentCodePoint]; verified exhaustively over U+0000–10FFFF,
/// alone and inside canonical-reordering probes, by the test suite). Those
/// 36 are unassigned starters in Unicode 16: NFKD leaves them unchanged and
/// no combining mark is reordered across them. So the input is split at
/// them, `unorm.nfkd` runs on the pieces in between, and the pieces are
/// joined around the untouched code points; that is exactly Python's result.
///
/// Lone surrogates pass through unchanged (as in Python), so strict UTF-8
/// encoding afterwards reports them at Python's position.
String pythonNfkd(String s) {
  StringBuffer? out;
  var start = 0;
  final it = s.runes.iterator;
  while (it.moveNext()) {
    if (!_isUnormDivergentCodePoint(it.current)) continue;
    final buffer = out ??= StringBuffer();
    if (it.rawIndex > start) {
      buffer.write(unorm.nfkd(s.substring(start, it.rawIndex)));
    }
    buffer.writeCharCode(it.current);
    start = it.rawIndex + it.currentSize;
  }
  if (out == null) return unorm.nfkd(s);
  if (start < s.length) out.write(unorm.nfkd(s.substring(start)));
  return out.toString();
}

/// BIP39 mnemonic → 64-byte seed (python-mnemonic 0.21 semantics).
///
/// The phrase is normalised ([normalizeSeedPhrase]), NFKD-folded
/// ([pythonNfkd]), split on single spaces and must pass the English
/// wordlist + checksum test, else [Pin24Exception.bip39Invalid]. The seed is
/// PBKDF2-HMAC-SHA512(NFKD(phrase), "mnemonic" + NFKD([passphrase]), 2048);
/// a lone surrogate in the passphrase then throws
/// [Pin24Exception.passphraseNotUtf8]. The passphrase is not trimmed or
/// case-folded.
///
/// The returned buffer belongs to the caller, who should zero it after use.
Uint8List bip39ToSeed(String phrase, {String passphrase = ''}) {
  final nfkdPhrase = pythonNfkd(normalizeSeedPhrase(phrase));
  if (!bip39ChecksumValid(nfkdPhrase.split(' '))) {
    throw const Pin24Exception(
      Pin24Exception.bip39Invalid,
      _bip39InvalidMessage,
    );
  }
  final salt = _utf8Strict(
    'mnemonic${pythonNfkd(passphrase)}',
    Pin24Exception.passphraseNotUtf8,
  );
  // A valid phrase is plain ASCII after NFKD.
  final password = utf8.encode(nfkdPhrase);
  try {
    return _pbkdf2HmacSha512(password, salt, 2048);
  } finally {
    password.fillRange(0, password.length, 0);
    salt.fillRange(0, salt.length, 0);
  }
}

/// PBKDF2-HMAC-SHA512 (RFC 8018) for a 64-byte key, i.e. exactly one block:
/// T = U1 ^ … ^ Uc with U1 = HMAC(P, S ‖ INT(1)), Ui = HMAC(P, Ui−1).
///
/// pointycastle's `PBKDF2KeyDerivator` keeps copies of the password, the
/// output and its state in buffers it never clears; this version owns every
/// buffer, zeroes U and S ‖ INT(1) always and T on error, and scrubs the
/// HMAC key pads before returning.
Uint8List _pbkdf2HmacSha512(Uint8List password, Uint8List salt, int rounds) {
  const hLen = 64;
  final mac = HMac(SHA512Digest(), 128);
  final u = Uint8List(hLen);
  final t = Uint8List(hLen);
  final block = Uint8List(salt.length + 4);
  var ok = false;
  try {
    mac.init(KeyParameter(password));
    block
      ..setRange(0, salt.length, salt)
      ..[salt.length + 3] = 1; // INT(1), big-endian
    mac
      ..update(block, 0, block.length)
      ..doFinal(u, 0);
    t.setRange(0, hLen, u);
    for (var i = 1; i < rounds; i++) {
      mac
        ..update(u, 0, hLen)
        ..doFinal(u, 0);
      for (var j = 0; j < hLen; j++) {
        t[j] ^= u[j];
      }
    }
    ok = true;
    return t;
  } finally {
    u.fillRange(0, hLen, 0);
    block.fillRange(0, block.length, 0);
    if (!ok) t.fillRange(0, hLen, 0);
    _scrubHmac(mac);
  }
}

/// Overwrites an [HMac]'s key-dependent state (`key ^ ipad`, `key ^ opad`
/// and the digest's state/W buffer) with constants: re-initialising with an
/// empty key reuses the same buffers.
void _scrubHmac(HMac mac) => mac.init(KeyParameter(Uint8List(0)));

// ─────────────────────────────────────────────────────────────────────────────
// Public derivation API
// ─────────────────────────────────────────────────────────────────────────────

/// The exact password Ledger Passwords would type for [nickname].
///
/// Pass exactly one of [seedPhrase] (BIP39 words, optionally with
/// [bip39Passphrase]) or [bip39Seed] (64 raw bytes; the passphrase is then
/// ignored). [nickname] is used as raw UTF-8: no trimming, case folding or
/// Unicode normalisation. [setMask] defaults to NUMBERS | BARS, the device's
/// "numbers + separators" toggles.
///
/// Throws [Pin24Exception]; checks run in the Python order: seed source,
/// BIP39, passphrase UTF-8, seed length, nickname empty, nickname UTF-8,
/// size, mask, `minFromSet` length, minimums vs size, `size > 256`
/// ([Pin24Exception.moduloRange]). The last two are decided before any
/// allocation or draw, so a huge [size] fails fast (see [sampleUnshuffled]).
String derivePassword({
  String? seedPhrase,
  Uint8List? bip39Seed,
  required String nickname,
  int setMask = kPinMask,
  List<int> minFromSet = kDefaultMinSet,
  int size = kPasswordMaxSize,
  String bip39Passphrase = '',
}) {
  if ((seedPhrase == null) == (bip39Seed == null)) {
    throw const Pin24Exception(
      Pin24Exception.exactlyOneSeedSource,
      'Pass exactly one of seed_phrase / bip39_seed',
    );
  }
  final ownedSeed = seedPhrase == null
      ? null
      : bip39ToSeed(seedPhrase, passphrase: bip39Passphrase);
  final seed = ownedSeed ?? bip39Seed!;
  try {
    if (seed.length != 64) {
      throw Pin24Exception(
        Pin24Exception.seedLength,
        'BIP39 seed must be exactly 64 bytes, got ${seed.length}',
      );
    }
    if (nickname.isEmpty) {
      throw const Pin24Exception(
        Pin24Exception.nicknameEmpty,
        'nickname must be non-empty',
      );
    }
    final entropy = _leafEntropy(seed, nicknamePath(nickname));
    final drbg = CtrDrbg.instantiate(entropy);
    entropy.fillRange(0, entropy.length, 0);
    try {
      final bytes = _generatePassword(drbg, setMask, minFromSet, size);
      final password = String.fromCharCodes(bytes);
      bytes.fillRange(0, bytes.length, 0);
      return password;
    } finally {
      drbg.wipe();
    }
  } finally {
    ownedSeed?.fillRange(0, ownedSeed.length, 0);
  }
}

/// The first [length] digits of the NUMBERS | BARS password for [nickname],
/// right-padded with `0` when the 20-character password has fewer digits.
String derivePin({
  String? seedPhrase,
  Uint8List? bip39Seed,
  required String nickname,
  required int length,
  String bip39Passphrase = '',
}) =>
    derivePinDetailed(
      seedPhrase: seedPhrase,
      bip39Seed: bip39Seed,
      nickname: nickname,
      length: length,
      bip39Passphrase: bip39Passphrase,
    ).pin;

/// A PIN plus the data the UI needs to let the user cross-check it against
/// the device.
class PinDerivation {
  const PinDerivation({
    required this.pin,
    required this.fullPassword,
    required this.digitsInOutput,
    required this.paddedZeros,
  });

  /// Exactly the requested number of digits.
  final String pin;

  /// The 20-character NUMBERS | BARS password the device would type.
  final String fullPassword;

  /// How many digits [fullPassword] contains.
  final int digitsInOutput;

  /// How many trailing `0`s were appended (a local convention, not device
  /// behaviour: the user must pad the same way when comparing by hand).
  final int paddedZeros;

  bool get isPadded => paddedZeros > 0;
}

/// Same result as [derivePin], with the full password and padding details.
PinDerivation derivePinDetailed({
  String? seedPhrase,
  Uint8List? bip39Seed,
  required String nickname,
  required int length,
  String bip39Passphrase = '',
}) {
  if (length <= 0) {
    throw const Pin24Exception(
      Pin24Exception.pinLengthNotPositive,
      'length must be positive',
    );
  }
  final full = derivePassword(
    seedPhrase: seedPhrase,
    bip39Seed: bip39Seed,
    nickname: nickname,
    setMask: kNumbers | kBars,
    bip39Passphrase: bip39Passphrase,
  );
  final digits = StringBuffer();
  for (final c in full.codeUnits) {
    if (c >= 0x30 && c <= 0x39) digits.writeCharCode(c);
  }
  final d = digits.toString();
  final pin = d.length >= length
      ? d.substring(0, length)
      : d + '0' * (length - d.length);
  return PinDerivation(
    pin: pin,
    fullPassword: full,
    digitsInOutput: d.length,
    paddedZeros: d.length >= length ? 0 : length - d.length,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Nickname → BIP32 path → leaf → entropy
// ─────────────────────────────────────────────────────────────────────────────

/// The 9-element hardened path for [nickname]: [kDerivePasswordPath], then
/// `0x80000000 | u32be(SHA-256(UTF-8(nickname))[4i..4i+4])` for i = 0..7.
///
/// Throws [Pin24Exception.nicknameNotUtf8] for a lone surrogate.
List<int> nicknamePath(String nickname) {
  final bytes = _utf8Strict(nickname, Pin24Exception.nicknameNotUtf8);
  final h = SHA256Digest().process(bytes);
  final path = <int>[kDerivePasswordPath];
  for (var i = 0; i < 8; i++) {
    final chunk = (h[4 * i] << 24) |
        (h[4 * i + 1] << 16) |
        (h[4 * i + 2] << 8) |
        h[4 * i + 3];
    path.add(0x80000000 | chunk);
  }
  bytes.fillRange(0, bytes.length, 0);
  h.fillRange(0, h.length, 0);
  return path;
}

/// SHA-256(leafKey ‖ leafChain) for the leaf at [path] below [seed].
Uint8List _leafEntropy(Uint8List seed, List<int> path) {
  var node = bip32Master(seed);
  try {
    for (final index in path) {
      final child = bip32HardenedChild(node.key, node.chain, index);
      node.wipe();
      node = child;
    }
    final material = Uint8List(64)
      ..setRange(0, 32, node.key)
      ..setRange(32, 64, node.chain);
    final entropy = SHA256Digest().process(material);
    material.fillRange(0, 64, 0);
    return entropy;
  } finally {
    node.wipe();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BIP32 (secp256k1, hardened only)
// ─────────────────────────────────────────────────────────────────────────────

/// A BIP32 private node. Owns its buffers; call [wipe] when done.
class Bip32Node {
  Bip32Node(this.key, this.chain);

  /// 32-byte private key, 1 ≤ key < n.
  final Uint8List key;

  /// 32-byte chain code.
  final Uint8List chain;

  void wipe() {
    key.fillRange(0, key.length, 0);
    chain.fillRange(0, chain.length, 0);
  }
}

/// BIP32 master node: HMAC-SHA512(key = "Bitcoin seed", data = [seed]).
Bip32Node bip32Master(Uint8List seed) {
  if (seed.length < 16 || seed.length > 64) {
    throw const Pin24Exception(
      Pin24Exception.bip32Invalid,
      'BIP32 master seed must be 16..64 bytes (typical: 64 for BIP39)',
    );
  }
  final i = _hmacSha512(_bitcoinSeedKey, seed);
  final key = Uint8List.fromList(Uint8List.sublistView(i, 0, 32));
  final chain = Uint8List.fromList(Uint8List.sublistView(i, 32, 64));
  i.fillRange(0, i.length, 0);
  if (_isZero(key) || _compareToN(key) >= 0) {
    key.fillRange(0, 32, 0);
    chain.fillRange(0, 32, 0);
    throw const Pin24Exception(
      Pin24Exception.bip32Invalid,
      'Invalid BIP32 master key (extremely unlikely)',
    );
  }
  return Bip32Node(key, chain);
}

/// Hardened child [index] (0x80000000..0xFFFFFFFF) of the node
/// ([key], [chain]): I = HMAC-SHA512(chain, 0x00 ‖ key ‖ ser32be(index)),
/// child key = (IL + key) mod n, child chain = IR.
///
/// Like the Python port, IL ≥ n raises instead of skipping to the next index.
Bip32Node bip32HardenedChild(Uint8List key, Uint8List chain, int index) {
  if (index < 0x80000000 || index > 0xFFFFFFFF) {
    throw Pin24Exception(
      Pin24Exception.bip32Invalid,
      'Hardened index must be in [0x80000000, 0xFFFFFFFF]; '
      'got ${_pythonHex(index)}',
    );
  }
  if (key.length != 32 || chain.length != 32) {
    throw ArgumentError('BIP32 key and chain code must be 32 bytes each');
  }
  final data = Uint8List(37)
    ..setRange(1, 33, key)
    ..[33] = (index >> 24) & 0xff
    ..[34] = (index >> 16) & 0xff
    ..[35] = (index >> 8) & 0xff
    ..[36] = index & 0xff;
  final i = _hmacSha512(chain, data);
  data.fillRange(0, data.length, 0);
  final il = Uint8List.sublistView(i, 0, 32);
  if (_compareToN(il) >= 0) {
    i.fillRange(0, i.length, 0);
    throw const Pin24Exception(
      Pin24Exception.bip32Invalid,
      'BIP32 derived IL >= secp256k1 n; pick a different nickname',
    );
  }
  final childKey = _addModN(il, key);
  final childChain = Uint8List.fromList(Uint8List.sublistView(i, 32, 64));
  i.fillRange(0, i.length, 0);
  if (_isZero(childKey)) {
    childChain.fillRange(0, 32, 0);
    throw const Pin24Exception(
      Pin24Exception.bip32Invalid,
      'BIP32 child key is zero (astronomically unlikely)',
    );
  }
  return Bip32Node(childKey, childChain);
}

/// HMAC-SHA512 into a fresh buffer the caller owns and wipes; the HMAC's
/// key pads are scrubbed before returning.
Uint8List _hmacSha512(Uint8List key, Uint8List data) {
  final mac = HMac(SHA512Digest(), 128);
  try {
    mac.init(KeyParameter(key));
    return mac.process(data);
  } finally {
    _scrubHmac(mac);
  }
}

bool _isZero(Uint8List bytes) {
  var acc = 0;
  for (final b in bytes) {
    acc |= b;
  }
  return acc == 0;
}

/// Compares a 32-byte big-endian value with n: <0, 0 or >0.
int _compareToN(Uint8List v) {
  for (var i = 0; i < 32; i++) {
    final d = v[i] - _secp256k1N33[i + 1];
    if (d != 0) return d;
  }
  return 0;
}

/// (a + b) mod n on 32-byte big-endian values, without BigInt so that every
/// intermediate can be wiped.
Uint8List _addModN(Uint8List a, Uint8List b) {
  final sum = Uint8List(33);
  var carry = 0;
  for (var i = 31; i >= 0; i--) {
    final s = a[i] + b[i] + carry;
    sum[i + 1] = s & 0xff;
    carry = s >> 8;
  }
  sum[0] = carry;
  // a < n and b < 2^256, so at most two subtractions are needed.
  while (_compare33(sum, _secp256k1N33) >= 0) {
    var borrow = 0;
    for (var i = 32; i >= 0; i--) {
      final d = sum[i] - _secp256k1N33[i] - borrow;
      sum[i] = d & 0xff;
      borrow = d < 0 ? 1 : 0;
    }
  }
  final out = Uint8List.fromList(Uint8List.sublistView(sum, 1));
  sum.fillRange(0, sum.length, 0);
  return out;
}

int _compare33(Uint8List a, Uint8List b) {
  for (var i = 0; i < 33; i++) {
    final d = a[i] - b[i];
    if (d != 0) return d;
  }
  return 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// mbedtls CTR_DRBG-AES-256 as configured by BOLOS for app-passwords
// ─────────────────────────────────────────────────────────────────────────────

/// pointycastle's [AESEngine] whose round-key schedules can be wiped.
///
/// `AESEngine.init` allocates a new schedule on every call (through the
/// public `generateWorkingKey`) and simply drops the previous one, so
/// re-keying never erases old round keys. This subclass remembers the
/// schedule it handed out, zeroes the previous one in place on every re-key,
/// and zeroes the current one on [wipeKeySchedule]. The block state itself
/// lives in locals only.
class WipeableAesEngine extends AESEngine {
  List<List<int>>? _schedule;

  @override
  List<List<int>> generateWorkingKey(
    bool forEncryption,
    KeyParameter params,
  ) {
    final schedule = super.generateWorkingKey(forEncryption, params);
    wipeKeySchedule();
    _schedule = schedule;
    return schedule;
  }

  /// Zeroes the current round keys in place. The engine then encrypts with
  /// an all-zero schedule (not a valid AES key) until it is re-initialised.
  void wipeKeySchedule() {
    final schedule = _schedule;
    if (schedule == null) return;
    for (final round in schedule) {
      round.fillRange(0, round.length, 0);
    }
    _schedule = null;
  }
}

/// NIST SP 800-90A block-cipher derivation function, mbedtls flavour
/// (`block_cipher_df` in `ctr_drbg.c`): CBC-MAC under key 00 01 … 1F over
/// IV ‖ u32be(len) ‖ u32be(48) ‖ [data] ‖ 0x80, three times with only IV byte
/// 3 incremented, then three chained encryptions under the result.
Uint8List blockCipherDf(Uint8List data) {
  if (data.length > _maxSeedInput) {
    throw ArgumentError('CTR_DRBG df input too large');
  }
  final bufLen = _blockSize + 8 + data.length + 1;
  final buf = Uint8List(bufLen)
    ..setRange(_blockSize + 8, _blockSize + 8 + data.length, data)
    ..[bufLen - 1] = 0x80;
  ByteData.sublistView(buf)
    ..setUint32(_blockSize, data.length)
    ..setUint32(_blockSize + 4, _seedLen);

  final aes = WipeableAesEngine()
    ..init(
      true,
      KeyParameter(Uint8List.fromList(List<int>.generate(_keySize, (i) => i))),
    );
  final tmp = Uint8List(_seedLen);
  final chain = Uint8List(_blockSize);
  final outKey = Uint8List(_keySize);
  final iv = Uint8List(_blockSize);
  final out = Uint8List(_seedLen);
  var ok = false;
  try {
    _blockCipherDfInto(aes, buf, bufLen, tmp, chain, outKey, iv, out);
    ok = true;
    return out;
  } finally {
    for (final b in [buf, tmp, chain, outKey, iv]) {
      b.fillRange(0, b.length, 0);
    }
    if (!ok) out.fillRange(0, out.length, 0);
    aes.wipeKeySchedule();
  }
}

/// The CBC-MAC and output stages of [blockCipherDf], writing into buffers
/// the caller owns and wipes.
void _blockCipherDfInto(
  WipeableAesEngine aes,
  Uint8List buf,
  int bufLen,
  Uint8List tmp,
  Uint8List chain,
  Uint8List outKey,
  Uint8List iv,
  Uint8List out,
) {
  for (var j = 0; j < _seedLen; j += _blockSize) {
    chain.fillRange(0, _blockSize, 0);
    var p = 0;
    var useLen = bufLen;
    while (useLen > 0) {
      final take = useLen < _blockSize ? useLen : _blockSize;
      for (var i = 0; i < take; i++) {
        chain[i] ^= buf[p + i];
      }
      aes.processBlock(chain, 0, tmp, j);
      chain.setRange(0, _blockSize, tmp, j);
      p += _blockSize;
      useLen -= take;
    }
    buf[3] = (buf[3] + 1) & 0xff;
  }

  outKey.setRange(0, _keySize, tmp);
  iv.setRange(0, _blockSize, tmp, _keySize);
  aes.init(true, KeyParameter(outKey));
  for (var j = 0; j < _seedLen; j += _blockSize) {
    aes.processBlock(iv, 0, out, j);
    iv.setRange(0, _blockSize, out, j);
  }
}

/// mbedtls CTR_DRBG with AES-256 and the derivation function, as BOLOS
/// builds it for app-passwords: 32 bytes of entropy (MBEDTLS_SHA512_C is
/// undefined), no nonce, no personalisation, no additional input, no
/// prediction resistance and no reseed.
///
/// Owns its key and counter; call [wipe] when done.
class CtrDrbg {
  CtrDrbg._();

  /// `mbedtls_ctr_drbg_seed` with [entropy32] as the whole seed material:
  /// K = 0, V = 0, then update(df(entropy)).
  factory CtrDrbg.instantiate(Uint8List entropy32) {
    if (entropy32.length != 32) {
      throw ArgumentError('entropy32 must be 32 bytes');
    }
    // Load the all-zero initial K; _update() re-keys after every change.
    final drbg = CtrDrbg._().._rekey();
    final seedMaterial = blockCipherDf(entropy32);
    drbg._update(seedMaterial);
    seedMaterial.fillRange(0, seedMaterial.length, 0);
    return drbg;
  }

  final Uint8List _key = Uint8List(_keySize);
  final Uint8List _v = Uint8List(_blockSize);
  final WipeableAesEngine _aes = WipeableAesEngine();
  int _generateCalls = 0;

  /// Copy of the current key K (for tests and cross-checks).
  Uint8List get key => Uint8List.fromList(_key);

  /// Copy of the current counter V (for tests and cross-checks).
  Uint8List get v => Uint8List.fromList(_v);

  /// Number of [generate] calls with `n > 0` so far. Each [rngU8Modulo]
  /// candidate byte is one call.
  int get generateCalls => _generateCalls;

  void _rekey() => _aes.init(true, KeyParameter(_key));

  static void _increment(Uint8List v) {
    for (var i = v.length - 1; i >= 0; i--) {
      v[i] = (v[i] + 1) & 0xff;
      if (v[i] != 0) break;
    }
  }

  /// `ctr_drbg_update_internal`.
  void _update(Uint8List data48) {
    final tmp = Uint8List(_seedLen);
    for (var j = 0; j < _seedLen; j += _blockSize) {
      _increment(_v);
      _aes.processBlock(_v, 0, tmp, j);
    }
    for (var i = 0; i < _seedLen; i++) {
      tmp[i] ^= data48[i];
    }
    _key.setRange(0, _keySize, tmp);
    _v.setRange(0, _blockSize, tmp, _keySize);
    tmp.fillRange(0, tmp.length, 0);
    _rekey();
  }

  /// `mbedtls_ctr_drbg_random_with_add(…, NULL, 0)`: [n] output bytes, then
  /// update(0^48). `n <= 0` returns an empty list and leaves the state alone.
  Uint8List generate(int n) {
    if (n <= 0) return Uint8List(0);
    _generateCalls++;
    final out = Uint8List(n);
    final block = Uint8List(_blockSize);
    for (var off = 0; off < n; off += _blockSize) {
      _increment(_v);
      _aes.processBlock(_v, 0, block, 0);
      final take = n - off < _blockSize ? n - off : _blockSize;
      out.setRange(off, off + take, block);
    }
    block.fillRange(0, _blockSize, 0);
    _update(Uint8List(_seedLen));
    return out;
  }

  /// `rng_u8_modulo`: draw single bytes until one is ≤ 256 − (256 mod m),
  /// return it mod m. The `<=` (not `<`) copies the C code's slight bias and
  /// is required by the official vectors.
  ///
  /// Python only rejects m == 0 ("modulo must be > 0"); any m ≤ 0 is rejected
  /// here with that message.
  int rngU8Modulo(int modulo) {
    if (modulo <= 0) {
      throw const Pin24Exception(
        Pin24Exception.moduloRange,
        'modulo must be > 0',
      );
    }
    if (modulo > 256) {
      throw const Pin24Exception(
        Pin24Exception.moduloRange,
        'rng_u8_modulo only supports modulo <= 256',
      );
    }
    final limit = 256 - 256 % modulo;
    while (true) {
      final b = generate(1);
      final candidate = b[0];
      b[0] = 0;
      if (candidate <= limit) return candidate % modulo;
    }
  }

  /// Zeroes K, V and the AES round keys in place (every earlier schedule was
  /// already zeroed on re-key). The instance must not be used afterwards.
  void wipe() {
    _key.fillRange(0, _keySize, 0);
    _v.fillRange(0, _blockSize, 0);
    _aes.wipeKeySchedule();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Password generation (src/password_generation.c)
// ─────────────────────────────────────────────────────────────────────────────

/// First half of `generate_password`: for each enabled charset in bit order,
/// append it to the union and sample its minimum count; then fill the rest
/// from the union. Returns the unshuffled bytes (caller owns and wipes them).
///
/// Negative minimums count as 0; minimums of disabled sets are ignored. The
/// "minimums exceed size" check is overflow-safe (`minCount > size - offset`),
/// so minimums up to 2^63 − 1 give [Pin24Exception.minExceedsSize] like
/// Python instead of wrapping around.
///
/// `size > 256` can never produce a password: Python samples all `size`
/// bytes and then fails in the shuffle's first `rng_u8_modulo(size)`. The
/// outcome depends only on the minimums, so it is decided up front, before
/// any allocation or draw: [Pin24Exception.minExceedsSize] if the enabled
/// sets' positive minimums add up to more than [size] (Python checks them
/// first), else [Pin24Exception.moduloRange]. Only the number of DRBG draws
/// differs from Python ([drbg] is left untouched), and it is unobservable
/// through [derivePassword].
Uint8List sampleUnshuffled(
  CtrDrbg drbg, {
  required int setMask,
  required List<int> minFromSet,
  required int size,
}) {
  if (size <= 0) {
    throw const Pin24Exception(
      Pin24Exception.sizeNotPositive,
      'size must be positive',
    );
  }
  if (setMask <= 0 || setMask > 0xFF) {
    throw const Pin24Exception(
      Pin24Exception.setMaskRange,
      'set_mask must be in 1..255',
    );
  }
  if (minFromSet.length != _numSets) {
    throw const Pin24Exception(
      Pin24Exception.minFromSetLength,
      'min_from_set must have exactly $_numSets entries',
    );
  }
  if (size > 256) {
    var needed = 0;
    var remaining = setMask;
    for (var i = 0; i < _numSets && remaining != 0; i++, remaining >>= 1) {
      if (remaining & 1 == 0) continue;
      final minCount = minFromSet[i];
      if (minCount > 0) {
        if (minCount > size - needed) throw _minExceedsSize;
        needed += minCount;
      }
    }
    throw const Pin24Exception(
      Pin24Exception.moduloRange,
      'rng_u8_modulo only supports modulo <= 256',
    );
  }
  final out = Uint8List(size);
  try {
    var offset = 0;
    // A mask in 1..255 always enables at least one set, and the union of all
    // eight is 95 bytes, so Python's "empty union" / ">= 100 bytes" checks
    // can never fire.
    final union = <int>[];
    var remaining = setMask;
    for (var i = 0; i < _numSets && remaining != 0; i++, remaining >>= 1) {
      if (remaining & 1 == 0) continue;
      final charset = kCharsets[i].codeUnits;
      union.addAll(charset);
      final minCount = minFromSet[i];
      if (minCount > 0) {
        if (minCount > size - offset) throw _minExceedsSize;
        for (var k = 0; k < minCount; k++) {
          out[offset++] = charset[drbg.rngU8Modulo(charset.length)];
        }
      }
    }
    while (offset < size) {
      out[offset++] = union[drbg.rngU8Modulo(union.length)];
    }
    return out;
  } catch (_) {
    out.fillRange(0, out.length, 0);
    rethrow;
  }
}

const Pin24Exception _minExceedsSize = Pin24Exception(
  Pin24Exception.minExceedsSize,
  'min_from_set requires more chars than size allows',
);

/// Fisher-Yates as in `shuffle_array`: for i = len−1 down to 1,
/// j = rngU8Modulo(i + 1), swap. A buffer longer than 256 throws
/// [Pin24Exception.moduloRange] on the first step.
void shuffleInPlace(CtrDrbg drbg, Uint8List buffer) {
  for (var i = buffer.length - 1; i > 0; i--) {
    final j = drbg.rngU8Modulo(i + 1);
    final t = buffer[i];
    buffer[i] = buffer[j];
    buffer[j] = t;
  }
}

Uint8List _generatePassword(
  CtrDrbg drbg,
  int setMask,
  List<int> minFromSet,
  int size,
) {
  final out = sampleUnshuffled(
    drbg,
    setMask: setMask,
    minFromSet: minFromSet,
    size: size,
  );
  try {
    shuffleInPlace(drbg, out);
    return out;
  } catch (_) {
    out.fillRange(0, out.length, 0);
    rethrow;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Python str → UTF-8 (strict)
// ─────────────────────────────────────────────────────────────────────────────

/// UTF-8 bytes of [s], or [Pin24Exception] with [code] and Python's
/// UnicodeEncodeError text if [s] has an unpaired surrogate.
Uint8List _utf8Strict(String s, String code) {
  if (hasLoneSurrogate(s)) {
    throw Pin24Exception(code, _pythonSurrogateError(s));
  }
  return utf8.encode(s);
}

/// Python's `str(UnicodeEncodeError)` for the first run of surrogates in [s].
/// Positions are code-point indices, as in Python (a valid surrogate pair is
/// one code point; Dart's `runes` yields a lone surrogate as itself).
String _pythonSurrogateError(String s) {
  bool isSurrogate(int cp) => cp >= 0xD800 && cp <= 0xDFFF;
  final cps = s.runes.toList(growable: false);
  var start = 0;
  while (start < cps.length && !isSurrogate(cps[start])) {
    start++;
  }
  var end = start + 1;
  while (end < cps.length && isSurrogate(cps[end])) {
    end++;
  }
  const prefix = "'utf-8' codec can't encode";
  const reason = 'surrogates not allowed';
  if (end == start + 1) {
    final hex = cps[start].toRadixString(16).padLeft(4, '0');
    return "$prefix character '\\u$hex' in position $start: $reason";
  }
  return '$prefix characters in position $start-${end - 1}: $reason';
}

/// Python `f"{i:#x}"`.
String _pythonHex(int i) =>
    i < 0 ? '-0x${(-i).toRadixString(16)}' : '0x${i.toRadixString(16)}';

Uint8List _hexToBytes(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
