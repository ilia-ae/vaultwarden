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
/// Pure Dart (no Flutter imports), top-level functions only: run it through
/// `Isolate.run`, since PBKDF2 (2048 × HMAC-SHA512) dominates the cost.
///
/// Every buffer this library allocates for secret material (seed, BIP32
/// keys and chain codes, entropy, DRBG key/counter, password bytes) is
/// zeroed before it is dropped. Caller-owned inputs such as a raw seed are
/// never modified. pointycastle's internal state (AES round keys, HMAC pads)
/// and Dart `String`s cannot be wiped; they become garbage after the call.
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
  final String message;

  @override
  String toString() => 'Pin24Exception($code): $message';
}

// ─────────────────────────────────────────────────────────────────────────────
// BIP39
// ─────────────────────────────────────────────────────────────────────────────

/// Python `" ".join(phrase.lower().split())`: lowercase, collapse runs of
/// Python whitespace (not Dart's `\s`: U+FEFF and U+200B are not separators,
/// U+001C–001F and U+0085 are) into single spaces, trim. No NFKD here.
String normalizeSeedPhrase(String phrase) =>
    pythonSplit(pythonLower(phrase)).join(' ');

/// BIP39 mnemonic → 64-byte seed (python-mnemonic 0.21 semantics).
///
/// The phrase is normalised ([normalizeSeedPhrase]), NFKD-folded, split on
/// single spaces and must pass the English wordlist + checksum test, else
/// [Pin24Exception.bip39Invalid]. The seed is
/// PBKDF2-HMAC-SHA512(NFKD(phrase), "mnemonic" + NFKD([passphrase]), 2048).
/// The passphrase is not trimmed or case-folded.
///
/// The returned buffer belongs to the caller, who should zero it after use.
Uint8List bip39ToSeed(String phrase, {String passphrase = ''}) {
  final nfkdPhrase = unorm.nfkd(normalizeSeedPhrase(phrase));
  if (!bip39ChecksumValid(nfkdPhrase.split(' '))) {
    throw const Pin24Exception(
      Pin24Exception.bip39Invalid,
      _bip39InvalidMessage,
    );
  }
  final salt = _utf8Strict(
    'mnemonic${unorm.nfkd(passphrase)}',
    Pin24Exception.passphraseNotUtf8,
  );
  // A valid phrase is plain ASCII after NFKD.
  final password = utf8.encode(nfkdPhrase);
  try {
    final kdf = PBKDF2KeyDerivator(HMac(SHA512Digest(), 128))
      ..init(Pbkdf2Parameters(salt, 2048, 64));
    return kdf.process(password);
  } finally {
    password.fillRange(0, password.length, 0);
    salt.fillRange(0, salt.length, 0);
  }
}

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
/// BIP39, seed length, nickname empty, nickname UTF-8, size, mask,
/// `minFromSet` length, minimums vs size, `size > 256`.
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

Uint8List _hmacSha512(Uint8List key, Uint8List data) {
  final mac = HMac(SHA512Digest(), 128)..init(KeyParameter(key));
  return mac.process(data);
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

  final aes = AESEngine()
    ..init(
      true,
      KeyParameter(Uint8List.fromList(List<int>.generate(_keySize, (i) => i))),
    );
  final tmp = Uint8List(_seedLen);
  final chain = Uint8List(_blockSize);
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

  final outKey = Uint8List.fromList(Uint8List.sublistView(tmp, 0, _keySize));
  final iv = Uint8List.fromList(Uint8List.sublistView(tmp, _keySize));
  aes.init(true, KeyParameter(outKey));
  final out = Uint8List(_seedLen);
  for (var j = 0; j < _seedLen; j += _blockSize) {
    aes.processBlock(iv, 0, out, j);
    iv.setRange(0, _blockSize, out, j);
  }
  for (final b in [buf, tmp, chain, outKey, iv]) {
    b.fillRange(0, b.length, 0);
  }
  return out;
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
  final AESEngine _aes = AESEngine();
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

  /// Zeroes K and V and drops the AES round keys. The instance must not be
  /// used afterwards.
  void wipe() {
    _key.fillRange(0, _keySize, 0);
    _v.fillRange(0, _blockSize, 0);
    _rekey();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Password generation (src/password_generation.c)
// ─────────────────────────────────────────────────────────────────────────────

/// First half of `generate_password`: for each enabled charset in bit order,
/// append it to the union and sample its minimum count; then fill the rest
/// from the union. Returns the unshuffled bytes (caller owns and wipes them).
///
/// Negative minimums count as 0; minimums of disabled sets are ignored.
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
        if (offset + minCount > size) {
          throw const Pin24Exception(
            Pin24Exception.minExceedsSize,
            'min_from_set requires more chars than size allows',
          );
        }
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
