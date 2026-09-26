import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/pin_tools/pin_shift.dart';

// Reference vectors generated from personal-crypto-tools
// (src/crypto_tools/pin_shift.py + pin_shift_ui.py) by running the real
// Python functions. `flutter test` runs with cwd = project root.
const _fixtures = 'test/pin_tools/fixtures';

Map<String, dynamic> _load(String name) =>
    jsonDecode(File('$_fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

List<Map<String, dynamic>> _list(Map<String, dynamic> json, String key) =>
    (json[key] as List).cast<Map<String, dynamic>>();

const _pinMsg = 'PIN must be a non-empty digit string';
const _shiftMsg = 'Shift must be a non-empty digit string';

/// Maps an exact Python ValueError message to the Dart error code.
String _codeForPythonMessage(String message) {
  if (message == _pinMsg) return PinShiftException.codePinInvalid;
  if (message == _shiftMsg) return PinShiftException.codeShiftInvalid;
  if (RegExp(r'^Shift length \(\d+\) must match PIN length \(\d+\)$')
      .hasMatch(message)) {
    return PinShiftException.codeLengthMismatch;
  }
  throw StateError('Unmapped Python message: $message');
}

Matcher _throwsShift(String code, String message) => throwsA(
      isA<PinShiftException>()
          .having((e) => e.code, 'code', code)
          .having((e) => e.message, 'message', message)
          .having((e) => e.toString(), 'toString()', message),
    );

String _complement(String v) => String.fromCharCodes(
      v.codeUnits.map((u) => 0x30 + (10 - (u - 0x30)) % 10),
    );

String _thousands(BigInt n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return buf.toString();
}

void main() {
  final vectors = _load('pin_shift.json');
  final errors = _load('pin_shift_errors.json');
  final ui = _load('pin_shift_ui.json');
  final bulk = _load('pin_shift_bulk.json');

  group('shiftPin — pin_shift.json vectors', () {
    final list = _list(vectors, 'vectors');

    test('fixture is complete (103 vectors, unique ids)', () {
      expect(list, hasLength(vectors['count'] as int));
      expect(list, hasLength(103));
      expect(list.map((v) => v['id']).toSet(), hasLength(list.length));
    });

    for (final v in list) {
      final pin = v['pin'] as String;
      final shift = v['shift'] as String;
      final decode = v['decode'] as bool;
      final expected = v['expected'] as String;

      test('${v['id']} (${decode ? 'decode' : 'encode'}, len ${v['length']})',
          () {
        expect(shiftPin(pin, shift, decode: decode), expected);
        expect(expected, hasLength(v['length'] as int));
        // Round trip, as recorded by Python.
        expect(v['roundtrip_ok'], isTrue);
        expect(
          shiftPin(expected, shift, decode: !decode),
          v['inverse_of_expected'],
        );
        expect(v['inverse_of_expected'], pin);
        // decode(p, v) == encode(p, complement(v)) and vice versa.
        expect(
          shiftPin(pin, _complement(shift), decode: !decode),
          expected,
        );
        // The breakdown table agrees with the core.
        expect(
          shiftBreakdown(pin, shift, decode: decode)
              .map((r) => r.output)
              .join(),
          expected,
        );
      });
    }
  });

  group('shiftPin — pin_shift_errors.json', () {
    final list = _list(errors, 'errors');

    // Python cases that pass a non-`str` argument. Dart's `String` parameters
    // make all of them compile-time errors, so they cannot be replayed.
    const staticallyImpossible = {
      't_rejects_int_shift',
      't_rejects_bool_shift',
      's_shift_none',
      's_shift_bytes',
      's_shift_float',
      's_shift_list',
      's_pin_none',
      's_pin_int_zero',
      's_pin_int',
      's_order_pin_before_shift_type',
    };

    // Python: isdigit() is True but int() then fails, leaking
    // "invalid literal for int() with base 10: 'X'". The port rejects these
    // characters up front with its regular validation error.
    const intLeakDivergence = {
      's_superscript_pin': PinShiftException.codePinInvalid,
      's_superscript_shift': PinShiftException.codeShiftInvalid,
      's_circled_digit_pin': PinShiftException.codePinInvalid,
    };

    test('fixture is complete (32 error cases, unique ids)', () {
      expect(list, hasLength(32));
      expect(list.map((e) => e['id']).toSet(), hasLength(list.length));
    });

    test('non-String Python inputs are exactly the known set', () {
      final nonString = {
        for (final e in list)
          if ((e['pin'] as Map)['type'] != 'str' ||
              (e['shift'] as Map)['type'] != 'str')
            e['id'] as String,
      };
      expect(nonString, staticallyImpossible);
      for (final e in list.where((e) => nonString.contains(e['id']))) {
        final py = e['python'] as Map<String, dynamic>;
        expect(py['ok'], isFalse);
        expect(
          py['error_type'],
          isIn(['TypeError', 'AttributeError', 'ValueError']),
        );
      }
      // Dart analogue of s_order_pin_before_shift_type: the PIN is checked
      // before anything about the shift.
      expect(() => shiftPin('', 'x'), _throwsShift('PIN_INVALID', _pinMsg));
    });

    for (final e in list) {
      final pin = e['pin'] as Map<String, dynamic>;
      final shift = e['shift'] as Map<String, dynamic>;
      if (pin['type'] != 'str' || shift['type'] != 'str') continue;
      final py = e['python'] as Map<String, dynamic>;
      final pyMessage = py['message'] as String;

      test('${e['id']}', () {
        expect(py['ok'], isFalse);
        expect(py['error_type'], 'ValueError');
        final String code;
        final String message;
        if (pyMessage.startsWith('invalid literal for int()')) {
          expect(intLeakDivergence.keys, contains(e['id']));
          code = intLeakDivergence[e['id']]!;
          message =
              code == PinShiftException.codePinInvalid ? _pinMsg : _shiftMsg;
        } else {
          expect(intLeakDivergence.keys, isNot(contains(e['id'])));
          code = _codeForPythonMessage(pyMessage);
          message = pyMessage;
        }
        final p = pin['value'] as String;
        final s = shift['value'] as String;
        final d = e['decode'] as bool;
        expect(() => shiftPin(p, s, decode: d), _throwsShift(code, message));
        expect(
          () => shiftBreakdown(p, s, decode: d),
          _throwsShift(code, message),
        );
      });
    }

    test('LENGTH_MISMATCH carries both lengths', () {
      try {
        shiftPin('12345678', '1234567', decode: true);
        fail('expected PinShiftException');
      } on PinShiftException catch (e) {
        expect(e.code, PinShiftException.codeLengthMismatch);
        expect(e.pinLength, 8);
        expect(e.shiftLength, 7);
      }
      try {
        shiftPin('12a4', '');
        fail('expected PinShiftException');
      } on PinShiftException catch (e) {
        expect(e.pinLength, isNull);
        expect(e.shiftLength, isNull);
      }
    });

    test('check order: PIN, then shift, then length', () {
      // Everything wrong: PIN reported.
      expect(
          () => shiftPin('1a', 'x2345'), _throwsShift('PIN_INVALID', _pinMsg));
      // Shift wrong and lengths differ: shift reported.
      expect(
        () => shiftPin('1234', 'x'),
        _throwsShift('SHIFT_INVALID', _shiftMsg),
      );
    });
  });

  group('divergence: Python accepts, port rejects', () {
    final list = _list(errors, 'python_accepts_but_port_should_reject');

    // Inputs that consist only of scripts normalizeInputDigits maps.
    const fixedByNormalization = {
      'd_fullwidth_pin',
      'd_arabic_indic_pin',
      'd_persian_shift',
      'd_mixed_ascii_fullwidth',
    };

    test('fixture has the 7 documented cases', () {
      expect(list, hasLength(7));
    });

    for (final e in list) {
      test('${e['id']}', () {
        final p = (e['pin'] as Map)['value'] as String;
        final s = (e['shift'] as Map)['value'] as String;
        final d = e['decode'] as bool;
        final dart = e['dart_recommended'] as Map<String, dynamic>;
        final py = e['python'] as Map<String, dynamic>;
        final message = dart['message'] as String;
        final code = _codeForPythonMessage(message);

        expect(dart['ok'], isFalse);
        expect(() => shiftPin(p, s, decode: d), _throwsShift(code, message));

        final np = normalizeInputDigits(p);
        final ns = normalizeInputDigits(s);
        if (fixedByNormalization.contains(e['id'])) {
          expect(py['ok'], isTrue);
          expect(shiftPin(np, ns, decode: d), py['result']);
        } else {
          // Devanagari / math-bold digits are deliberately not mapped.
          expect(
              () => shiftPin(np, ns, decode: d), _throwsShift(code, message));
        }
      });
    }
  });

  group('bulk parity — pin_shift_bulk.json (real Python, seeded)', () {
    final cases = _list(bulk, 'cases');

    test('all ${cases.length} cases match Python output or message', () {
      expect(cases, hasLength(bulk['count'] as int));
      var ok = 0;
      final mismatches = <String>[];
      for (final c in cases) {
        final p = c['p'] as String;
        final s = c['s'] as String;
        final d = c['d'] as bool;
        String actual;
        try {
          actual = 'o:${shiftPin(p, s, decode: d)}';
        } on PinShiftException catch (e) {
          expect(e.code, _codeForPythonMessage(e.message));
          actual = 'e:${e.message}';
        }
        final expected = c.containsKey('o') ? 'o:${c['o']}' : 'e:${c['e']}';
        if (actual == expected) {
          if (c.containsKey('o')) ok++;
        } else {
          mismatches.add('${jsonEncode(c)} -> $actual');
        }
      }
      expect(mismatches, isEmpty);
      expect(ok, greaterThan(100));
    });
  });

  group('properties', () {
    test('exhaustive length 1 and 2: round trip + complement', () {
      for (final len in [1, 2]) {
        final n = len == 1 ? 10 : 100;
        String fmt(int x) => x.toString().padLeft(len, '0');
        for (var a = 0; a < n; a++) {
          for (var b = 0; b < n; b++) {
            final p = fmt(a);
            final v = fmt(b);
            final enc = shiftPin(p, v);
            final dec = shiftPin(p, v, decode: true);
            expect(shiftPin(enc, v, decode: true), p);
            expect(shiftPin(dec, v), p);
            expect(dec, shiftPin(p, _complement(v)));
          }
        }
      }
    });

    test('random lengths 1..64: identities hold', () {
      final rnd = Random(20260926);
      String digits(int n) =>
          String.fromCharCodes(List.generate(n, (_) => 0x30 + rnd.nextInt(10)));
      for (var i = 0; i < 2000; i++) {
        final len = 1 + rnd.nextInt(64);
        final p = digits(len);
        final v = digits(len);
        final decode = rnd.nextBool();
        final out = shiftPin(p, v, decode: decode);
        expect(out, hasLength(len));
        expect(RegExp(r'^[0-9]+$').hasMatch(out), isTrue);
        expect(shiftPin(out, v, decode: !decode), p);
        expect(shiftPin(p, _complement(v), decode: !decode), out);
        final zeros = '0' * len;
        final fives = '5' * len;
        expect(shiftPin(p, zeros, decode: decode), p);
        expect(shiftPin(p, fives), shiftPin(p, fives, decode: true));
        expect(shiftPin(shiftPin(p, fives), fives), p);
      }
    });

    test('leading zeros survive and there is no carry', () {
      expect(shiftPin('9999', '1111'), '0000');
      expect(shiftPin('0000', '9999', decode: true), '1111');
      expect(shiftPin('0042', '0000'), '0042');
      expect(shiftPin('19', '01'), '10'); // no carry into column 0
    });

    test('runs in a background isolate (no Flutter dependency)', () async {
      final out = await Isolate.run(() => shiftPin('1234', '3719'));
      expect(out, '4943');
    });
  });

  group('UI helpers — pin_shift_ui.json', () {
    test('constants match the Streamlit page', () {
      final c = ui['constants'] as Map<String, dynamic>;
      expect(kShiftMinLength, c['MIN_LENGTH']);
      expect(kShiftMaxLength, c['MAX_LENGTH']);
      expect(kShiftDefaultLength, c['DEFAULT_LENGTH']);
      expect(kShiftQuickLengths, c['QUICK_LENGTHS']);
    });

    test('per-digit breakdown tables', () {
      final tables = _list(ui, 'per_digit_tables');
      expect(tables, hasLength(4));
      for (final t in tables) {
        final rows = shiftBreakdown(
          t['pin'] as String,
          t['shift'] as String,
          decode: t['decode'] as bool,
        );
        final expected = (t['rows'] as List).cast<Map<String, dynamic>>();
        expect(rows, hasLength(expected.length));
        for (var i = 0; i < rows.length; i++) {
          final r = rows[i];
          final x = expected[i];
          expect(r.position, x['#']);
          expect(r.input, x['input']);
          expect(r.vector, x['vector']);
          expect(r.formula, x['formula']);
          expect(r.output, x['output']);
          expect(r.decode, t['decode']);
          expect(
            r,
            ShiftBreakdownRow(
              position: x['#'] as int,
              input: x['input'] as int,
              vector: x['vector'] as int,
              output: x['output'] as int,
              decode: t['decode'] as bool,
            ),
          );
        }
      }
    });

    test('keyspace text 10^L = N for L in 1..16', () {
      final texts = (ui['keyspace_text'] as Map).cast<String, String>();
      expect(texts, hasLength(kShiftMaxLength - kShiftMinLength + 1));
      for (var l = kShiftMinLength; l <= kShiftMaxLength; l++) {
        final text = texts['$l']!;
        expect('10^$l = ${_thousands(shiftKeyspace(l))}', text);
        final n = BigInt.parse(text.split(' = ').last.replaceAll(',', ''));
        expect(shiftKeyspace(l), n);
      }
      expect(shiftKeyspace(0), BigInt.one);
      expect(shiftKeyspace(64), BigInt.parse('1${'0' * 64}'));
      expect(() => shiftKeyspace(-1), throwsRangeError);
    });

    test('digit grouping in fours for L in 1..16', () {
      final groups = (ui['digit_grouping'] as Map).cast<String, List>();
      for (var l = kShiftMinLength; l <= kShiftMaxLength; l++) {
        // Distinct characters make the index mapping observable.
        final s = String.fromCharCodes(List.generate(l, (i) => 0x41 + i));
        final expected = [
          for (final g in groups['$l']!)
            String.fromCharCodes((g as List).map((i) => 0x41 + (i as int))),
        ];
        expect(groupDigits(s), expected);
      }
    });

    test('groupDigits edge cases', () {
      expect(groupDigits(''), isEmpty);
      expect(groupDigits('12345', group: 2), ['12', '34', '5']);
      expect(groupDigits('123', group: 1), ['1', '2', '3']);
      expect(groupDigits('\u{1F600}\u{1F600}x', group: 2),
          ['\u{1F600}\u{1F600}', 'x']);
      expect(() => groupDigits('1', group: 0), throwsRangeError);
    });

    test('paper walkthrough fixtures are present for the UI', () {
      final md = (ui['paper_walkthrough_md'] as Map).cast<String, String>();
      expect(md.keys,
          containsAll(['4_encode', '4_decode', '8_encode', '8_decode']));
      // The worked example is the reference vector.
      expect(shiftPin('1234', '3719'), '4943');
      expect(shiftPin('4943', '3719', decode: true), '1234');
    });
  });

  group('normalizeInputDigits', () {
    test('maps Arabic-Indic, Extended Arabic-Indic and fullwidth digits', () {
      for (var d = 0; d < 10; d++) {
        expect(normalizeInputDigits(String.fromCharCode(0x0660 + d)), '$d');
        expect(normalizeInputDigits(String.fromCharCode(0x06F0 + d)), '$d');
        expect(normalizeInputDigits(String.fromCharCode(0xFF10 + d)), '$d');
      }
      expect(normalizeInputDigits('١٢٣٤'), '1234');
      expect(normalizeInputDigits('۳۷۱۹'), '3719');
      expect(normalizeInputDigits('１２３４'), '1234');
      expect(normalizeInputDigits('12３4'), '1234');
    });

    test('leaves other characters and digit scripts untouched', () {
      expect(normalizeInputDigits('४९४३'), '४९४३'); // Devanagari
      expect(normalizeInputDigits('\u{1D7CF}234'), '\u{1D7CF}234');
      expect(normalizeInputDigits('²①'), '²①');
      expect(normalizeInputDigits('12 34'), '12 34'); // inner space kept
      expect(normalizeInputDigits('\u{1F600}1'), '\u{1F600}1');
    });

    test('strips with Python str.strip() semantics', () {
      expect(normalizeInputDigits(' \t1234\n'), '1234');
      expect(normalizeInputDigits('\u{85}1234\u001C'), '1234');
      expect(normalizeInputDigits('\u{3000}1234\u00A0'), '1234');
      // U+FEFF and U+200B are not whitespace in Python.
      expect(normalizeInputDigits('\u{FEFF}1234'), '\u{FEFF}1234');
      expect(normalizeInputDigits('1234\u200B'), '1234\u200B');
      expect(normalizeInputDigits(''), '');
    });
  });

  group('nonDigitPositions', () {
    test('lists 1-based code-point positions, in order', () {
      expect(nonDigitPositions('1234'), isEmpty);
      expect(nonDigitPositions(''), isEmpty);
      expect(nonDigitPositions('12a4b'), [3, 5]);
      expect(nonDigitPositions('aa'), [1, 2]);
      // An astral character is one position, as in Python.
      expect(nonDigitPositions('1\u{1F600}2x'), [2, 4]);
      // A lone surrogate is one code point, as in Python.
      expect(nonDigitPositions('1\uD8002'), [2]);
      // Unmapped digit scripts are still non-digits for the core.
      expect(nonDigitPositions('१२2'), [1, 2]);
    });

    test('never exposes the offending characters', () {
      // Regression: the old nonDigitCharacters() returned the typed secret
      // characters, inviting the UI to echo masked input in its error.
      const secret = 'p4ss';
      final report = nonDigitPositions(secret);
      expect(report, isA<List<int>>());
      expect(report, [1, 3, 4]);
    });

    test('counts positions after normalizeInputDigits, like shiftPin', () {
      // Arabic-Indic digits map to ASCII; surrounding whitespace is stripped.
      expect(nonDigitPositions(normalizeInputDigits(' ١٢a٤ ')), [3]);
      expect(nonDigitPositions(normalizeInputDigits('١٢٣')), isEmpty);
    });

    test('agrees with shiftPin validation', () {
      final rng = Random(20260926);
      const alphabet = '0123456789a ١\u{1F600}';
      final chars = alphabet.runes.toList();
      for (var i = 0; i < 500; i++) {
        final s = String.fromCharCodes([
          for (var j = rng.nextInt(6); j > 0; j--)
            chars[rng.nextInt(chars.length)],
        ]);
        final valid = s.isNotEmpty && nonDigitPositions(s).isEmpty;
        if (valid) {
          expect(shiftPin(s, s), isA<String>());
        } else {
          expect(
            () => shiftPin(s, s),
            _throwsShift(PinShiftException.codePinInvalid, _pinMsg),
          );
        }
      }
    });
  });
}
