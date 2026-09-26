/// Legacy "mask" PIN generator.
///
/// Port of `generate_pin(mask_str, input_str)` from `pin/pass_pin.py`
/// (personal-crypto-tools, archived — superseded by PIN Shift). Generate-only;
/// there is no inverse.
///
/// Algorithm (exactly as the Python):
///  1. The mask is 8 single digits `m[0..7]`.
///  2. All whitespace (Python's set, see `python_text.dart`) is removed from
///     the input, which must then be exactly 20 code points. Any non-space
///     character is allowed, so the result is not necessarily numeric.
///  3. `pos = m[0] - 1` (absolute, 1-based), then `pos = (pos + m[i]) % 20`
///     (relative steps with wrap-around). Each visited element is emitted and
///     then overwritten with the character `0`, so a walk that returns to an
///     already-used position emits `0` — indistinguishable from a real `0`.
///
/// Deliberate divergence from Python: the mask accepts ASCII `0`–`9` only.
/// Python's `int()` also accepts any Unicode decimal digit (Arabic-Indic,
/// fullwidth, …); UI code should run the mask through
/// `normalizeInputDigits` (pin_shift.dart) first.
///
/// Pure Dart (no Flutter imports): safe for `Isolate.run` and plain tests.
library;

import 'python_text.dart';

/// Number of digits in a mask.
const int kMaskLength = 8;

/// Number of non-whitespace code points the input string must have.
const int kMaskInputLength = 20;

/// Validation failure raised by [maskPin] / [maskPinPositions].
///
/// [message] is the English translation used by the reference vectors,
/// [messageRu] the exact original Python (Russian) text, and [code] the
/// stable key the UI should map to a localized string.
class MaskPinException implements Exception {
  const MaskPinException._(
    this.code,
    this.message,
    this.messageRu, {
    this.position,
  });

  /// The mask is not exactly [kMaskLength] ASCII digits.
  const MaskPinException.maskFormat()
      : this._(
          codeMaskFormat,
          "The mask must contain exactly 8 digits, e.g. '24681357'.",
          "Маска должна содержать ровно 8 цифр, например, '24681357'.",
        );

  /// The whitespace-free input is not exactly [kMaskInputLength] code points.
  const MaskPinException.inputLength()
      : this._(
          codeInputLength,
          'The input string must contain exactly 20 characters '
              '(excluding whitespace).',
          'Входная строка должна содержать ровно 20 символов (без пробелов).',
        );

  /// Mask value at 1-based [position] is outside 1..20 (with single-digit
  /// masks this means it is `0`).
  MaskPinException.maskValueRange(int position)
      : this._(
          codeMaskValueRange,
          'Mask value at position $position must be between 1 and 20.',
          'Значение маски на позиции $position должно быть от 1 до 20.',
          position: position,
        );

  static const String codeMaskFormat = 'MASK_FORMAT';
  static const String codeInputLength = 'INPUT_LENGTH';
  static const String codeMaskValueRange = 'MASK_VALUE_RANGE';

  /// One of [codeMaskFormat], [codeInputLength], [codeMaskValueRange].
  final String code;

  /// English message (translation of [messageRu]).
  final String message;

  /// Exact Python message.
  final String messageRu;

  /// 1-based mask position; set only for [codeMaskValueRange].
  final int? position;

  @override
  String toString() => message;
}

/// Python: `mask = [int(c) for c in mask_str]` + `len(mask) == 8`, restricted
/// to ASCII digits. No stripping — `generate_pin` does not strip the mask.
List<int> _parseMask(String mask) {
  final values = <int>[];
  for (final r in mask.runes) {
    if (r < 0x30 || r > 0x39) throw const MaskPinException.maskFormat();
    values.add(r - 0x30);
  }
  if (values.length != kMaskLength) throw const MaskPinException.maskFormat();
  return values;
}

/// The walk, including Python's in-loop 1..20 range check that reports the
/// first offending 1-based position.
List<int> _walk(List<int> steps) {
  final positions = <int>[];
  var pos = 0;
  for (var i = 0; i < steps.length; i++) {
    final m = steps[i];
    if (m < 1 || m > 20) throw MaskPinException.maskValueRange(i + 1);
    pos = i == 0 ? m - 1 : (pos + m) % kMaskInputLength;
    positions.add(pos);
  }
  return positions;
}

/// Python `list(''.join(input_str.strip().split()))`: the code points of
/// [input] that are not Python whitespace, in order.
///
/// Taken from the runes of the original string, never from a re-joined one:
/// joining would make a lone high surrogate and a lone low surrogate that
/// were separated by whitespace adjacent, and Dart would then read them as
/// one astral code point where Python keeps two.
List<int> _maskElements(String input) => [
      for (final r in input.runes)
        if (!isPythonSpace(r)) r,
    ];

/// Python `''.join(input_str.strip().split())`: [input] with every Python
/// whitespace character removed (same UTF-16 content as the Python string).
///
/// Count with [maskInputLength], not with this string's runes: a lone high
/// and a lone low surrogate that were separated by whitespace end up adjacent
/// here, so Dart reads them as one code point where Python counts two.
String normalizeMaskInput(String input) =>
    String.fromCharCodes(_maskElements(input));

/// Python `len(''.join(input_str.strip().split()))`: the number of
/// non-whitespace code points in [input], which must equal
/// [kMaskInputLength]. Use it for a live "n / 20" counter.
int maskInputLength(String input) => _maskElements(input).length;

/// Generates the 8-character mask PIN from [mask] and [input].
///
/// Check order matches Python: mask format, then input length, then the
/// per-step value range. Lengths are counted in code points (runes), so an
/// emoji is one character. Throws [MaskPinException] on invalid input.
String maskPin(String mask, String input) {
  final steps = _parseMask(mask);
  final elements = _maskElements(input);
  if (elements.length != kMaskInputLength) {
    throw const MaskPinException.inputLength();
  }
  final out = <int>[];
  for (final pos in _walk(steps)) {
    out.add(elements[pos]);
    // Python: `elements[current_pos] = '0'` — a revisit yields '0'.
    elements[pos] = 0x30;
  }
  return String.fromCharCodes(out);
}

/// The 0-based input positions visited by [mask], in order (revisits
/// included), e.g. `24681357` → `[1, 5, 11, 19, 0, 3, 8, 15]`.
///
/// Throws [MaskPinException] with [MaskPinException.codeMaskFormat] or
/// [MaskPinException.codeMaskValueRange]; no input is involved.
List<int> maskPinPositions(String mask) => _walk(_parseMask(mask));

/// The 0-based step indices at which [mask] revisits an already-used
/// position, i.e. the output characters that are forced to `0`.
List<int> maskPinRevisitSteps(String mask) {
  final positions = maskPinPositions(mask);
  final seen = <int>{};
  final revisits = <int>[];
  for (var i = 0; i < positions.length; i++) {
    if (!seen.add(positions[i])) revisits.add(i);
  }
  return revisits;
}
