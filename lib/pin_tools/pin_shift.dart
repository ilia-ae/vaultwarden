/// PIN Shift: per-position modulo-10 shift of a digit PIN by a secret vector.
///
/// Port of `crypto_tools.pin_shift.shift_pin` (personal-crypto-tools) plus the
/// pure helpers behind its Streamlit page (`crypto_tools/pin_shift_ui.py`).
///
///     out[i] = (pin[i] + sign * shift[i]) mod 10,  sign = decode ? -1 : +1
///
/// Every position is independent (no carry between columns) and the output
/// keeps the input length, so leading zeros survive (`9999` + `1111` =
/// `0000`). This is a Caesar-style mnemonic / obfuscation aid, not a cipher.
///
/// Deliberate divergence from Python: the core accepts ASCII `0`–`9` only.
/// Python's `str.isdigit()` also accepts every Unicode digit (fullwidth,
/// Arabic-Indic, Persian, Devanagari, math-bold …), and leaks a raw
/// `invalid literal for int()` error for superscript / circled digits that
/// pass `isdigit()` but fail `int()`. Here all of those are rejected with the
/// regular [PinShiftException.pinInvalid] / [PinShiftException.shiftInvalid]
/// errors. UI code should run text-field input through [normalizeInputDigits]
/// first so Arabic-locale keyboards still work.
///
/// Pure Dart (no Flutter imports): safe for `Isolate.run` and plain tests.
library;

import 'python_text.dart';

/// Smallest PIN / vector length the UI offers (`MIN_LENGTH`).
const int kShiftMinLength = 1;

/// Largest PIN / vector length the UI offers (`MAX_LENGTH`). The core
/// [shiftPin] itself has no maximum.
const int kShiftMaxLength = 16;

/// Length pre-selected when the screen opens (`DEFAULT_LENGTH`).
const int kShiftDefaultLength = 4;

/// Lengths offered as one-tap quick picks (`QUICK_LENGTHS`).
const List<int> kShiftQuickLengths = [4, 8];

/// Validation failure raised by [shiftPin] / [shiftBreakdown].
///
/// [message] is byte-for-byte the Python `ValueError` text so it can be
/// compared against the reference vectors; [code] is the stable key the UI
/// should map to a localized string.
class PinShiftException implements Exception {
  const PinShiftException._(
    this.code,
    this.message, {
    this.pinLength,
    this.shiftLength,
  });

  /// `pin` is empty or contains anything other than ASCII `0`–`9`.
  const PinShiftException.pinInvalid()
      : this._(codePinInvalid, 'PIN must be a non-empty digit string');

  /// `shift` is empty or contains anything other than ASCII `0`–`9`.
  const PinShiftException.shiftInvalid()
      : this._(codeShiftInvalid, 'Shift must be a non-empty digit string');

  /// Both inputs are valid digit strings but their lengths differ.
  PinShiftException.lengthMismatch({
    required int pinLength,
    required int shiftLength,
  }) : this._(
          codeLengthMismatch,
          'Shift length ($shiftLength) must match PIN length ($pinLength)',
          pinLength: pinLength,
          shiftLength: shiftLength,
        );

  static const String codePinInvalid = 'PIN_INVALID';
  static const String codeShiftInvalid = 'SHIFT_INVALID';
  static const String codeLengthMismatch = 'LENGTH_MISMATCH';

  /// One of [codePinInvalid], [codeShiftInvalid], [codeLengthMismatch].
  final String code;

  /// Exact Python error message.
  final String message;

  /// Set only for [codeLengthMismatch], for localized messages.
  final int? pinLength;

  /// Set only for [codeLengthMismatch], for localized messages.
  final int? shiftLength;

  @override
  String toString() => message;
}

bool _isAsciiDigit(int unit) => unit >= 0x30 && unit <= 0x39;

bool _isAsciiDigitString(String s) {
  if (s.isEmpty) return false;
  for (var i = 0; i < s.length; i++) {
    if (!_isAsciiDigit(s.codeUnitAt(i))) return false;
  }
  return true;
}

/// Python's check order: PIN, then shift, then length.
void _validate(String pin, String shift) {
  if (!_isAsciiDigitString(pin)) throw const PinShiftException.pinInvalid();
  if (!_isAsciiDigitString(shift)) {
    throw const PinShiftException.shiftInvalid();
  }
  // Both are ASCII here, so UTF-16 length == code-point length == Python len().
  if (shift.length != pin.length) {
    throw PinShiftException.lengthMismatch(
      pinLength: pin.length,
      shiftLength: shift.length,
    );
  }
}

/// Shifts every digit of [pin] by the digit at the same position of [shift],
/// modulo 10 — adding when encoding, subtracting when [decode] is true.
///
/// The core does not strip whitespace (only the UI does) and has no maximum
/// length. Throws [PinShiftException] on invalid input.
String shiftPin(String pin, String shift, {bool decode = false}) {
  _validate(pin, shift);
  final sign = decode ? -1 : 1;
  final out = List<int>.filled(pin.length, 0);
  for (var i = 0; i < pin.length; i++) {
    final p = pin.codeUnitAt(i) - 0x30;
    final s = shift.codeUnitAt(i) - 0x30;
    // Dart's `%` with a positive divisor is never negative, like Python's.
    out[i] = 0x30 + (p + sign * s) % 10;
  }
  return String.fromCharCodes(out);
}

/// Maps Arabic-Indic (U+0660–0669), Extended Arabic-Indic / Persian
/// (U+06F0–06F9) and fullwidth (U+FF10–FF19) digits to ASCII `0`–`9`, then
/// strips leading/trailing whitespace with Python `str.strip()` semantics.
///
/// Anything else (including other digit scripts) is left untouched, so
/// [shiftPin] will still reject it. Use on raw text-field input before
/// validation; the Python page likewise `.strip()`s both fields.
String normalizeInputDigits(String s) {
  final units = s.codeUnits;
  final out = List<int>.filled(units.length, 0);
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u >= 0x0660 && u <= 0x0669) {
      out[i] = 0x30 + (u - 0x0660);
    } else if (u >= 0x06F0 && u <= 0x06F9) {
      out[i] = 0x30 + (u - 0x06F0);
    } else if (u >= 0xFF10 && u <= 0xFF19) {
      out[i] = 0x30 + (u - 0xFF10);
    } else {
      // All mapped ranges are in the BMP, so surrogate pairs pass through
      // unchanged as two code units.
      out[i] = u;
    }
  }
  return pythonStrip(String.fromCharCodes(out));
}

/// 1-based code-point positions of the characters of [s] that are not ASCII
/// `0`–`9`, in order. Empty when [s] is all digits (or empty); the list's
/// length is the number of offending characters.
///
/// The PIN and the vector are secrets typed into masked fields, so this
/// reports only *where* the problem is, never *what* was typed. The Python
/// page's "Non-digit characters in PIN: `a`, `b`" error echoes the
/// characters; the UI must instead show a fixed localized message (at most
/// with these positions or their count), even when reveal is on. Pass the
/// same string that goes to [shiftPin], i.e. after [normalizeInputDigits].
List<int> nonDigitPositions(String s) {
  final positions = <int>[];
  var position = 0;
  for (final r in s.runes) {
    position++;
    if (!_isAsciiDigit(r)) positions.add(position);
  }
  return positions;
}

/// Number of possible vectors (and derived PINs) of [length] digits:
/// `10^length`, the page's "Keyspace if vector is private".
BigInt shiftKeyspace(int length) {
  RangeError.checkNotNegative(length, 'length');
  return BigInt.from(10).pow(length);
}

/// One row of the "Per-digit breakdown" table.
class ShiftBreakdownRow {
  const ShiftBreakdownRow({
    required this.position,
    required this.input,
    required this.vector,
    required this.output,
    this.decode = false,
  });

  /// 1-based column number (the table's `#` column).
  final int position;

  /// Digit of the PIN being transformed (base when encoding, derived when
  /// decoding).
  final int input;

  /// Digit of the shift vector at this position.
  final int vector;

  /// `(input ± vector) mod 10`.
  final int output;

  /// Whether this row subtracts (decode) rather than adds.
  final bool decode;

  /// The table's formula cell, e.g. `(4 + 9) mod 10` or `(3 − 9) mod 10`
  /// (decode uses U+2212 MINUS SIGN, as the Python page does).
  String get formula => '($input ${decode ? '−' : '+'} $vector) mod 10';

  @override
  bool operator ==(Object other) =>
      other is ShiftBreakdownRow &&
      other.position == position &&
      other.input == input &&
      other.vector == vector &&
      other.output == output &&
      other.decode == decode;

  @override
  int get hashCode => Object.hash(position, input, vector, output, decode);

  @override
  String toString() => 'ShiftBreakdownRow(#$position: $formula = $output)';
}

/// Per-position breakdown of `shiftPin(pin, shift, decode: decode)`.
///
/// Validates exactly like [shiftPin] and throws the same
/// [PinShiftException]s.
List<ShiftBreakdownRow> shiftBreakdown(
  String pin,
  String shift, {
  bool decode = false,
}) {
  _validate(pin, shift);
  final sign = decode ? -1 : 1;
  final rows = <ShiftBreakdownRow>[];
  for (var i = 0; i < pin.length; i++) {
    final d = pin.codeUnitAt(i) - 0x30;
    final s = shift.codeUnitAt(i) - 0x30;
    rows.add(
      ShiftBreakdownRow(
        position: i + 1,
        input: d,
        vector: s,
        output: (d + sign * s) % 10,
        decode: decode,
      ),
    );
  }
  return rows;
}

/// Splits [s] into consecutive chunks of [group] characters (code points);
/// the last chunk may be shorter. The page draws a `–` separator between
/// chunks of 4 digit cells. Returns an empty list for an empty string.
List<String> groupDigits(String s, {int group = 4}) {
  if (group < 1) throw RangeError.range(group, 1, null, 'group');
  final runes = s.runes.toList();
  return [
    for (var i = 0; i < runes.length; i += group)
      String.fromCharCodes(
        runes.sublist(i, i + group < runes.length ? i + group : runes.length),
      ),
  ];
}
