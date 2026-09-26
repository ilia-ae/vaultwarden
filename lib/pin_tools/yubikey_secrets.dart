/// Dart port of the secret generation in yubikey-fleet
/// `bin/yk-batch-secrets.py` (the FIELDS table, `random` and `derived` modes,
/// OTP-from-serial, the `--check` rules and the `--bitwarden` CSV export).
///
/// The Python script is the ground truth; every behaviour here is pinned by
/// vectors generated from it (test/pin_tools/fixtures/yubikey_*.json).
///
/// Things that are easy to get wrong:
///
/// * `derived` mode is NOT RFC 5869 HKDF. The key material is
///   `HMAC-SHA256(master, info || 0x01) || HMAC-SHA256(master, info || 0x02)
///   || …` with the raw master as the HMAC key: no Extract step and no
///   `T(i-1)` chaining. Block 1 happens to equal HKDF-Expand, block 2 matches
///   nothing standard, so an HKDF library gives wrong values.
/// * The master key is the key file's raw bytes with ASCII whitespace
///   stripped from both ends. Nothing is decoded: a file holding 64 hex
///   characters is a 64-byte ASCII key.
/// * The info string is `yk-fleet/{serial}/{NN}` with NN the field number. It
///   has no salt, batch or version: one master + serial always gives the same
///   secrets. The serial is only stripped, never normalised, so `"0012389"`
///   and `"12389"` are different keys.
/// * The OTP access code from the serial is Python `f"{int(serial):012d}"`,
///   including `int()`'s acceptance of Unicode decimal digits, `_` separators
///   and a sign.
///
/// YAML manifest parsing, `--fill` text splicing and ykman provisioning are
/// desktop-only and deliberately not ported.
///
/// Pure Dart (no Flutter imports), so it runs in `Isolate.run` and plain
/// `dart test`. No function here logs or embeds a secret value in an error.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/api.dart' show KeyParameter;
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/macs/hmac.dart';

import 'python_text.dart';

// ──────────────────────────────────────────────
// Errors
// ──────────────────────────────────────────────

/// A failure the script would also stop on. [message] never contains a
/// secret value.
class YkException implements Exception {
  /// Stripped master key is shorter than 32 bytes.
  static const masterTooShort = 'MASTER_TOO_SHORT';

  /// Rejection sampling ran out of key material (the script never computes
  /// extra HMAC blocks, so this is a hard error).
  static const okmExhausted = 'OKM_EXHAUSTED';

  /// Field number is not in [ykFields].
  static const unknownField = 'UNKNOWN_FIELD';

  /// Requested length is outside the field's `[min, max]`.
  static const lengthOutOfRange = 'LENGTH_OUT_OF_RANGE';

  /// Serial is empty, not encodable as UTF-8, not a Python `int()` literal
  /// (OTP-from-serial), or unsafe for the unquoted CSV export (a comma,
  /// quote or line break, or a leading `=` `+` `-` `@` a spreadsheet would
  /// run as a formula).
  static const serialInvalid = 'SERIAL_INVALID';

  /// A value fails the `--check` rules (or is unsafe for the unquoted CSV)
  /// when exporting.
  static const valueInvalid = 'VALUE_INVALID';

  final String code;
  final String message;

  const YkException(this.code, this.message);

  @override
  String toString() => 'YkException($code): $message';
}

// ──────────────────────────────────────────────
// FIELDS table
// ──────────────────────────────────────────────

const _digits = '0123456789';
const _alphanumeric =
    'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
const _hexLower = '0123456789abcdef';

/// One row of the script's `FIELDS` table.
///
/// The bounds are the fleet's policy, stricter than the hardware (e.g. the
/// OpenPGP Admin PIN may be 8–127 on the card, the fleet uses 8–16).
class YkField {
  /// Two-digit Bitwarden field number; permanently bound to [name].
  final String number;
  final String name;

  /// Inclusive length bounds, in code points (Python `len`).
  final int min;
  final int max;

  /// Characters in index order — the order matters because values are
  /// picked by index (`string.digits`, `ascii_letters + digits` with
  /// lowercase first, or lowercase hex).
  final String alphabet;

  const YkField({
    required this.number,
    required this.name,
    required this.min,
    required this.max,
    required this.alphabet,
  });

  @override
  String toString() => 'YkField($number $name, $min..$max)';
}

/// The script's `FIELDS`, in its insertion order (which is also numeric).
const Map<String, YkField> ykFields = {
  '00':
      YkField(number: '00', name: 'piv.pin', min: 6, max: 8, alphabet: _digits),
  '14':
      YkField(number: '14', name: 'piv.puk', min: 6, max: 8, alphabet: _digits),
  '23': YkField(
      number: '23',
      name: 'openpgp.user-pin',
      min: 8,
      max: 16,
      alphabet: _alphanumeric),
  '24': YkField(
      number: '24',
      name: 'openpgp.admin-pin',
      min: 8,
      max: 16,
      alphabet: _alphanumeric),
  '25': YkField(
      number: '25',
      name: 'openpgp.reset-code',
      min: 8,
      max: 24,
      alphabet: _alphanumeric),
  '34': YkField(
      number: '34',
      name: 'fido2.pin',
      min: 8,
      max: 16,
      alphabet: _alphanumeric),
  '41': YkField(
      number: '41',
      name: 'oath.password',
      min: 16,
      max: 32,
      alphabet: _alphanumeric),
  '45': YkField(
      number: '45',
      name: 'otp.slot1.access-code',
      min: 12,
      max: 12,
      alphabet: _hexLower),
  '46': YkField(
      number: '46',
      name: 'otp.slot2.access-code',
      min: 12,
      max: 12,
      alphabet: _hexLower),
};

YkField _field(String field) {
  final spec = ykFields[field];
  if (spec == null) {
    throw YkException(YkException.unknownField, 'unknown field "$field"');
  }
  return spec;
}

/// Provisioning phases that add fields. The script's `hygiene`, `slots` and
/// `verify` phases add none, so they are not modelled.
enum YkPhase { openpgp, fido2, oath, otp }

/// Field numbers the enabled [phases] need, sorted by number. PIV PIN (00)
/// and PUK (14) are always needed.
List<String> ykNeededFields(Set<YkPhase> phases) => [
      '00',
      '14',
      if (phases.contains(YkPhase.openpgp)) ...['23', '24', '25'],
      if (phases.contains(YkPhase.fido2)) '34',
      if (phases.contains(YkPhase.oath)) '41',
      if (phases.contains(YkPhase.otp)) ...['45', '46'],
    ];

/// `batch.secrets` in the manifest.
enum YkMode { random, derived }

/// Length the script generates: the field max in random mode,
/// `min(max, max(min, 12))` in derived mode.
int ykDefaultLength(String field, YkMode mode) {
  final spec = _field(field);
  return switch (mode) {
    YkMode.random => spec.max,
    YkMode.derived => min(spec.max, max(spec.min, 12)),
  };
}

int _checkedLength(YkField spec, int length) {
  if (length < spec.min || length > spec.max) {
    throw YkException(
      YkException.lengthOutOfRange,
      'field ${spec.number} (${spec.name}): length $length, '
      'allowed ${spec.min}..${spec.max}',
    );
  }
  return length;
}

// ──────────────────────────────────────────────
// Master key
// ──────────────────────────────────────────────

/// Minimum stripped master-key length in bytes.
const ykMinMasterKeyLength = 32;

/// Python `bytes.isspace()` set: space, \t, \n, \r, \v, \f. Unlike
/// `str.strip()` it does NOT include 0x1C–0x1F, 0x85 or 0xA0.
bool _isAsciiSpaceByte(int b) =>
    b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0B || b == 0x0C;

/// The script's `Path(mk).read_bytes().strip()` plus its `>= 32 bytes` rule.
///
/// Returns a new buffer holding only the stripped key; it is the caller's to
/// store (secure storage) and to zero when done. [raw] is not modified —
/// zero it yourself if it was a temporary buffer. No other copy is made.
///
/// Throws [YkException] `MASTER_TOO_SHORT`, or [ArgumentError] if [raw]
/// holds a value outside 0..255.
Uint8List ykNormalizeMasterKey(List<int> raw) {
  for (var i = 0; i < raw.length; i++) {
    final b = raw[i];
    if (b < 0 || b > 255) {
      throw ArgumentError('master key must be bytes (0..255)');
    }
  }
  var start = 0;
  var end = raw.length;
  while (start < end && _isAsciiSpaceByte(raw[start])) {
    start++;
  }
  while (end > start && _isAsciiSpaceByte(raw[end - 1])) {
    end--;
  }
  final length = end - start;
  if (length < ykMinMasterKeyLength) {
    throw YkException(
      YkException.masterTooShort,
      'master key is shorter than $ykMinMasterKeyLength bytes ($length)',
    );
  }
  final out = Uint8List(length);
  for (var i = 0; i < length; i++) {
    out[i] = raw[start + i];
  }
  return out;
}

/// A master passed to derivation must already be what
/// [ykNormalizeMasterKey] returns; otherwise the desktop script (which
/// strips) would derive different secrets from the same file.
void _checkMaster(Uint8List master) {
  if (master.isNotEmpty &&
      (_isAsciiSpaceByte(master.first) || _isAsciiSpaceByte(master.last))) {
    throw ArgumentError(
      'master key is not normalised: pass the result of ykNormalizeMasterKey',
    );
  }
  if (master.length < ykMinMasterKeyLength) {
    throw YkException(
      YkException.masterTooShort,
      'master key is shorter than $ykMinMasterKeyLength bytes '
      '(${master.length})',
    );
  }
}

// ──────────────────────────────────────────────
// Serial
// ──────────────────────────────────────────────

/// `str(serial).strip()` plus the script's "serial not specified" stop.
/// A lone surrogate would make Python's strict UTF-8 encoder (info string,
/// CSV write) raise, so it is rejected here too.
String _normalizeSerial(String serial) {
  final s = pythonStrip(serial);
  if (s.isEmpty) {
    throw const YkException(YkException.serialInvalid, 'serial is empty');
  }
  if (hasLoneSurrogate(s)) {
    throw const YkException(
      YkException.serialInvalid,
      'serial contains an unpaired UTF-16 surrogate',
    );
  }
  return s;
}

/// Code point of digit zero for every Unicode decimal-digit run (general
/// category Nd, Unicode 16 — the table of the Python 3.14 used to generate
/// the vectors). Each run is zero..nine. Python `int()` accepts all of them.
const List<int> _unicodeDecimalZeros = [
  0x0030, 0x0660, 0x06F0, 0x07C0, 0x0966, 0x09E6, 0x0A66, 0x0AE6, //
  0x0B66, 0x0BE6, 0x0C66, 0x0CE6, 0x0D66, 0x0DE6, 0x0E50, 0x0ED0, //
  0x0F20, 0x1040, 0x1090, 0x17E0, 0x1810, 0x1946, 0x19D0, 0x1A80, //
  0x1A90, 0x1B50, 0x1BB0, 0x1C40, 0x1C50, 0xA620, 0xA8D0, 0xA900, //
  0xA9D0, 0xA9F0, 0xAA50, 0xABF0, 0xFF10, 0x104A0, 0x10D30, 0x10D40, //
  0x11066, 0x110F0, 0x11136, 0x111D0, 0x112F0, 0x11450, 0x114D0, //
  0x11650, 0x116C0, 0x116D0, 0x116DA, 0x11730, 0x118E0, 0x11950, //
  0x11BF0, 0x11C50, 0x11D50, 0x11DA0, 0x11F50, 0x16130, 0x16A60, //
  0x16AC0, 0x16B50, 0x16D70, 0x1CCF0, 0x1D7CE, 0x1D7D8, 0x1D7E2, //
  0x1D7EC, 0x1D7F6, 0x1E140, 0x1E2F0, 0x1E4F0, 0x1E5F1, 0x1E950, //
  0x1FBF0,
];

int _decimalValue(int codePoint) {
  for (final zero in _unicodeDecimalZeros) {
    if (codePoint >= zero && codePoint <= zero + 9) return codePoint - zero;
  }
  return -1;
}

/// Python's default `sys.get_int_max_str_digits()`: `int()` refuses longer
/// decimal literals (leading zeros count, `_` separators do not).
const _pythonIntMaxStrDigits = 4300;

const _serialNotInteger = YkException(
  YkException.serialInvalid,
  'serial is not an integer, so no OTP access code can be made from it',
);

/// Python `f"{int(serial):012d}"`: the OTP access code both slots get when
/// `options.otp_access_from_serial` is on (e.g. `12345678` → `000012345678`).
///
/// Mirrors `int()` exactly: surrounding whitespace (the ASCII six plus
/// non-ASCII Unicode spaces — but not U+001C–001F), one optional sign,
/// Unicode decimal digits, single `_` between digits, at most 4300 digits.
/// A negative serial gives `-` plus 11 digits; a serial of 13+ digits gives a
/// 13+ character code — both are produced (like the script) and then fail
/// [ykCheckValue]. Throws [YkException] `SERIAL_INVALID` where `int()`
/// raises.
String ykOtpFromSerial(String serial) {
  // CPython first maps non-ASCII spaces to ' ' and non-ASCII decimal digits
  // to ASCII; any other non-ASCII character ends the literal (invalid).
  final chars = <int>[];
  for (final r in serial.runes) {
    if (r < 0x7F) {
      chars.add(r);
    } else if (isPythonSpace(r)) {
      chars.add(0x20);
    } else {
      final d = _decimalValue(r);
      if (d < 0) throw _serialNotInteger;
      chars.add(0x30 + d);
    }
  }
  var i = 0;
  while (i < chars.length && _isAsciiSpaceByte(chars[i])) {
    i++;
  }
  var negative = false;
  if (i < chars.length && (chars[i] == 0x2B || chars[i] == 0x2D)) {
    negative = chars[i] == 0x2D;
    i++;
  }
  final digits = StringBuffer();
  var digitCount = 0;
  var prevUnderscore = false;
  var sawDigit = false;
  while (i < chars.length) {
    final c = chars[i];
    if (c >= 0x30 && c <= 0x39) {
      digits.writeCharCode(c);
      digitCount++;
      sawDigit = true;
      prevUnderscore = false;
    } else if (c == 0x5F) {
      // `_` only between digits, never doubled.
      if (!sawDigit || prevUnderscore) throw _serialNotInteger;
      prevUnderscore = true;
    } else {
      break;
    }
    i++;
  }
  if (!sawDigit || prevUnderscore) throw _serialNotInteger;
  if (digitCount > _pythonIntMaxStrDigits) throw _serialNotInteger;
  while (i < chars.length && _isAsciiSpaceByte(chars[i])) {
    i++;
  }
  if (i != chars.length) throw _serialNotInteger;

  var magnitude = digits.toString().replaceFirst(RegExp('^0+'), '');
  if (magnitude.isEmpty) {
    magnitude = '0';
    negative = false; // int('-0') == 0
  }
  return negative
      ? '-${magnitude.padLeft(11, '0')}'
      : magnitude.padLeft(12, '0');
}

// ──────────────────────────────────────────────
// Derived mode
// ──────────────────────────────────────────────

/// Result of the script's rejection sampler over a key-material buffer.
typedef YkSample = ({String value, int bytesConsumed, int bytesRejected});

/// The script's byte-to-character sampler, exposed for tests and tooling.
///
/// `limit = (256 ~/ n) * n` (250 for digits, 248 for alphanumeric, 256 for
/// hex). Bytes are read in order; a byte `b < limit` appends
/// `alphabet[b % n]`, others are skipped; reading stops at [length]
/// characters. Running out first throws `OKM_EXHAUSTED` — the script never
/// computes extra blocks, and neither may a port.
YkSample ykSampleOkm(List<int> okm, String alphabet, int length) {
  final chars = alphabet.runes.toList(growable: false);
  final n = chars.length;
  if (n == 0) throw ArgumentError.value(alphabet, 'alphabet', 'is empty');
  final limit = (256 ~/ n) * n;
  final out = StringBuffer();
  var produced = 0;
  var consumed = 0;
  var rejected = 0;
  for (final b in okm) {
    if (produced == length) break;
    if (b < 0 || b > 255) throw ArgumentError('okm must be bytes (0..255)');
    consumed++;
    if (b < limit) {
      out.writeCharCode(chars[b % n]);
      produced++;
    } else {
      rejected++;
    }
  }
  if (produced < length) {
    throw const YkException(
      YkException.okmExhausted,
      'key material ran out before the value was complete',
    );
  }
  return (
    value: out.toString(),
    bytesConsumed: consumed,
    bytesRejected: rejected,
  );
}

/// Full trace of one derived value: the inputs to HMAC, the key material and
/// the sampler counts. For tests and diagnostics only — [okm] is secret
/// material; call [wipe] when done and never log any of it.
class YkDerivation {
  /// UTF-8 of `yk-fleet/{serial}/{field}`.
  final Uint8List info;

  /// `block_1 || … || block_hmacBlocks`, 32 bytes each.
  final Uint8List okm;
  final int hmacBlocks;
  final int bytesConsumed;
  final int bytesRejected;
  final String value;

  const YkDerivation({
    required this.info,
    required this.okm,
    required this.hmacBlocks,
    required this.bytesConsumed,
    required this.bytesRejected,
    required this.value,
  });

  /// Zeroes [okm].
  void wipe() => okm.fillRange(0, okm.length, 0);

  @override
  String toString() => 'YkDerivation(<redacted>, $hmacBlocks block(s))';
}

/// [ykDerive] with every intermediate kept; see [YkDerivation].
YkDerivation ykDeriveTrace({
  required Uint8List master,
  required String serial,
  required String field,
  int? length,
}) {
  final spec = _field(field);
  final len =
      _checkedLength(spec, length ?? ykDefaultLength(field, YkMode.derived));
  _checkMaster(master);
  final s = _normalizeSerial(serial);

  final info = utf8.encode('yk-fleet/$s/${spec.number}');
  // Python: `while len(okm) < length * 2` → ceil(2·length / 32) blocks, all
  // computed up front.
  final blocks = (2 * len + 31) ~/ 32;
  final okm = Uint8List(blocks * 32);
  final digest = SHA256Digest();
  final hmac = HMac(digest, 64)..init(KeyParameter(master));
  try {
    for (var counter = 1; counter <= blocks; counter++) {
      hmac
        ..update(info, 0, info.length)
        ..updateByte(counter);
      hmac.doFinal(okm, (counter - 1) * 32);
    }
  } finally {
    // HMac keeps `key XOR ipad/opad` in private buffers; re-keying with an
    // empty key overwrites them, and reset() clears the digest's state.
    hmac.init(KeyParameter(Uint8List(0)));
    digest.reset();
  }

  final YkSample sample;
  try {
    sample = ykSampleOkm(okm, spec.alphabet, len);
  } catch (_) {
    okm.fillRange(0, okm.length, 0);
    rethrow;
  }
  return YkDerivation(
    info: info,
    okm: okm,
    hmacBlocks: blocks,
    bytesConsumed: sample.bytesConsumed,
    bytesRejected: sample.bytesRejected,
    value: sample.value,
  );
}

/// The script's `derive(master, serial, field, length, alphabet)`.
///
/// [master] must be the output of [ykNormalizeMasterKey] (>= 32 bytes, no
/// surrounding ASCII whitespace; otherwise `MASTER_TOO_SHORT` or
/// [ArgumentError]). [serial] is stripped like `str(serial).strip()` and used
/// verbatim otherwise. [length] defaults to [ykDefaultLength] for derived
/// mode and must lie within the field's bounds (`LENGTH_OUT_OF_RANGE`).
///
/// Only the returned string survives: key material is zeroed before return.
String ykDerive({
  required Uint8List master,
  required String serial,
  required String field,
  int? length,
}) {
  final d = ykDeriveTrace(
      master: master, serial: serial, field: field, length: length);
  d.wipe();
  return d.value;
}

// ──────────────────────────────────────────────
// Random mode
// ──────────────────────────────────────────────

/// Stand-in for `Random.secure().nextInt`: returns an index in `0..max-1`.
typedef YkNextInt = int Function(int max);

/// The script's `random_value`: each character `secrets.choice(alphabet)`,
/// i.e. `alphabet[Random.secure().nextInt(n)]` (unbiased). [length] defaults
/// to the field max. No extra constraints (repeats allowed, no weak-value
/// filter) — like the script.
///
/// [nextIntForTest] is a test hook only (recording or replaying draws).
/// Production code must omit it: [Random.secure] is the only source these
/// secrets may come from, and a seeded or plain [Random] would make them
/// predictable. It deliberately takes a function, not a [Random], so a
/// `Random()` cannot be passed in by mistake.
String ykRandom(String field, {int? length, YkNextInt? nextIntForTest}) {
  final spec = _field(field);
  final len =
      _checkedLength(spec, length ?? ykDefaultLength(field, YkMode.random));
  final nextInt = nextIntForTest ?? Random.secure().nextInt;
  final alphabet = spec.alphabet;
  final out = StringBuffer();
  for (var i = 0; i < len; i++) {
    out.write(alphabet[nextInt(alphabet.length)]);
  }
  return out.toString();
}

// ──────────────────────────────────────────────
// --check
// ──────────────────────────────────────────────

enum YkValueProblemKind { length, alphabet }

/// One `--check` failure, structured so the UI can localise it. Never holds
/// the value itself.
class YkValueProblem {
  final YkValueProblemKind kind;
  final YkField field;

  /// Value length in code points (Python `len`).
  final int length;

  const YkValueProblem({
    required this.kind,
    required this.field,
    required this.length,
  });

  /// English rendering of the script's `✗` line (without the serial).
  String get message => switch (kind) {
        YkValueProblemKind.length =>
          'field ${field.number} (${field.name}): length $length, '
              'allowed ${field.min}..${field.max}',
        YkValueProblemKind.alphabet =>
          'field ${field.number} (${field.name}): invalid characters',
      };

  @override
  String toString() => message;
}

/// The script's per-value check as structured problems, in the script's
/// order (length first). Empty means the card will accept the value.
List<YkValueProblem> ykValidateValue(String field, String value) {
  final spec = _field(field);
  final runes = value.runes.toList(growable: false);
  final allowed = spec.alphabet.runes.toSet();
  return [
    if (runes.length < spec.min || runes.length > spec.max)
      YkValueProblem(
          kind: YkValueProblemKind.length, field: spec, length: runes.length),
    if (runes.any((r) => !allowed.contains(r)))
      YkValueProblem(
          kind: YkValueProblemKind.alphabet, field: spec, length: runes.length),
  ];
}

/// `--check` for one value: length within `[min, max]` (code points) and
/// every character in the field alphabet. Returns human-readable problems
/// (English, no value echoed); empty list = OK. Like the script it does not
/// flag weak/factory values or duplicates across fields.
List<String> ykCheckValue(String field, String value) =>
    [for (final p in ykValidateValue(field, value)) p.message];

// ──────────────────────────────────────────────
// Per-key resolution
// ──────────────────────────────────────────────

/// Resolved secrets of one key. [values] maps field number → value in
/// [ykNeededFields] order.
class YkKeySecrets {
  final String serial;
  final Map<String, String> values;

  const YkKeySecrets({required this.serial, required this.values});

  @override
  String toString() =>
      'YkKeySecrets($serial, fields: ${values.keys.join(',')})';
}

/// Resolves every needed field of one key the way the script's main loop
/// does. Per field, first match wins:
///
/// 1. fields 45/46 when [otpFromSerial] (only if [YkPhase.otp] is enabled —
///    otherwise they are not needed): [ykOtpFromSerial], overriding even a
///    manual value;
/// 2. a non-empty [manual] value (both modes; entries for fields not needed
///    are ignored, as in the script);
/// 3. [ykRandom] (field max length) or [ykDerive] (derived default length).
///
/// Checks run in the script's order: in derived mode [master] first — it is
/// required ([ArgumentError] if null or not normalised, `MASTER_TOO_SHORT`)
/// and checked even when every field ends up manual — then [serial], which
/// is stripped (`SERIAL_INVALID` if empty). So a bad master is reported
/// before a bad serial, as the desktop script does. Values are NOT checked
/// here; run [ykCheckValue] (the export does it for you). In random mode the
/// generated values exist only in the result: persist them before exporting,
/// or the export holds secrets that exist nowhere else.
///
/// [nextIntForTest] is the [ykRandom] test hook; production code must omit
/// it so random mode draws from [Random.secure].
YkKeySecrets ykResolveKey({
  required String serial,
  required Set<YkPhase> phases,
  required YkMode mode,
  Uint8List? master,
  bool otpFromSerial = false,
  Map<String, String> manual = const {},
  YkNextInt? nextIntForTest,
}) {
  // The script validates the master once, before it looks at any key.
  if (mode == YkMode.derived) {
    if (master == null) {
      throw ArgumentError.notNull('master');
    }
    _checkMaster(master);
  }
  final s = _normalizeSerial(serial);
  YkNextInt? nextInt = nextIntForTest;
  String? otpCode;
  final out = <String, String>{};
  for (final f in ykNeededFields(phases)) {
    if ((f == '45' || f == '46') && otpFromSerial) {
      out[f] = otpCode ??= ykOtpFromSerial(s);
      continue;
    }
    final have = manual[f];
    if (have != null && have.isNotEmpty) {
      out[f] = have;
      continue;
    }
    out[f] = switch (mode) {
      YkMode.random =>
        ykRandom(f, nextIntForTest: nextInt ??= Random.secure().nextInt),
      YkMode.derived => ykDerive(master: master!, serial: s, field: f),
    };
  }
  return YkKeySecrets(serial: s, values: Map.unmodifiable(out));
}

// ──────────────────────────────────────────────
// --bitwarden CSV
// ──────────────────────────────────────────────

bool _csvUnsafe(String s) =>
    s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r');

/// A spreadsheet opening the file reads a cell starting with one of these as
/// a formula (CSV/formula injection). Tab and CR are listed for
/// completeness; a stripped serial cannot start with either.
bool _spreadsheetFormula(String s) => s.isNotEmpty && '=+-@\t\r'.contains(s[0]);

/// The script's `--bitwarden` export, byte for byte: header
/// `folder,name,field,value`, then per key (in [keys] order) and per field
/// (sorted by number) `yk-fleet,{serial},{NN} {name},{value}`; LF endings,
/// trailing newline, no quoting.
///
/// Like the script, every value is checked first ([ykCheckValue]) and
/// nothing is exported if any fails (`VALUE_INVALID`, `UNKNOWN_FIELD`), and
/// keys with the same serial collapse into one entry (Python dict: first
/// position, last values).
///
/// Intentional divergences (the script writes these files unchanged):
///
/// * The script does not quote, so a comma, quote or line break in a serial
///   or value would silently corrupt its CSV; here that throws
///   (`SERIAL_INVALID` / `VALUE_INVALID`) instead. Checked values cannot
///   contain them, so the check only matters for serials.
/// * A serial starting with `=`, `+`, `-` or `@` (e.g. `+12_345`, which the
///   script accepts and `int()` reads as 12345) is refused with
///   `SERIAL_INVALID`: a spreadsheet opening the file would run it as a
///   formula next to plaintext secrets. Checked values cannot start with
///   these (their alphabets are letters and digits).
///
/// Serial guards run before the value check, so a file with both kinds of
/// problem reports `SERIAL_INVALID`. Serials must be as [ykResolveKey]
/// returns them (stripped, non-empty); deriving from any serial is
/// unaffected, only the export refuses.
///
/// The result holds plaintext secrets: write it to the app sandbox with
/// owner-only permissions, hand it to the share sheet, delete it after.
String ykBitwardenCsv(List<YkKeySecrets> keys) {
  if (keys.isEmpty) {
    throw ArgumentError.value(keys, 'keys', 'no keys to export');
  }
  final bySerial = <String, Map<String, String>>{};
  for (final k in keys) {
    final serial = k.serial;
    if (serial.isEmpty || pythonStrip(serial) != serial) {
      throw const YkException(
        YkException.serialInvalid,
        'serial is empty or not stripped',
      );
    }
    if (hasLoneSurrogate(serial) || _csvUnsafe(serial)) {
      throw const YkException(
        YkException.serialInvalid,
        'serial contains a character the unquoted CSV cannot carry',
      );
    }
    if (_spreadsheetFormula(serial)) {
      throw const YkException(
        YkException.serialInvalid,
        'serial starts with a character a spreadsheet reads as a formula',
      );
    }
    bySerial[serial] = k.values;
  }

  final problems = <String>[];
  for (final MapEntry(key: serial, value: values) in bySerial.entries) {
    for (final MapEntry(key: f, value: v) in values.entries) {
      for (final p in ykCheckValue(f, v)) {
        problems.add('$serial $p');
      }
      if (_csvUnsafe(v)) {
        problems.add('$serial field $f: character unsafe for unquoted CSV');
      }
    }
  }
  if (problems.isNotEmpty) {
    throw YkException(
      YkException.valueInvalid,
      'values do not fit the hardware: ${problems.join('; ')}',
    );
  }

  final sb = StringBuffer('folder,name,field,value');
  for (final MapEntry(key: serial, value: values) in bySerial.entries) {
    final fields = values.keys.toList()..sort();
    for (final f in fields) {
      sb
        ..write('\n')
        ..write('yk-fleet,$serial,$f ${ykFields[f]!.name},${values[f]}');
    }
  }
  sb.write('\n');
  return sb.toString();
}

// ──────────────────────────────────────────────
// Operator checksum
// ──────────────────────────────────────────────

/// First 6 hex characters of SHA-256 over the UTF-8 value — the checksum an
/// operator reads back to confirm a value without revealing it
/// (`lib/secret-input.sh` `_sha`). [ArgumentError] on a lone surrogate
/// (Python's encoder raises too).
String ykSha256Prefix6(String value) {
  if (hasLoneSurrogate(value)) {
    throw ArgumentError('value contains an unpaired UTF-16 surrogate');
  }
  final bytes = utf8.encode(value);
  final digest = SHA256Digest();
  try {
    final hash = digest.process(bytes);
    final sb = StringBuffer();
    for (var i = 0; i < 3; i++) {
      sb.write(hash[i].toRadixString(16).padLeft(2, '0'));
    }
    hash.fillRange(0, hash.length, 0);
    return sb.toString();
  } finally {
    bytes.fillRange(0, bytes.length, 0);
    digest.reset();
  }
}
