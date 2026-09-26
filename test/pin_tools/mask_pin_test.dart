import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/pin_tools/mask_pin.dart';
import 'package:vault_approver/pin_tools/pin_shift.dart'
    show normalizeInputDigits;
import 'package:vault_approver/pin_tools/python_text.dart';

// Reference vectors generated from personal-crypto-tools pin/pass_pin.py by
// running the real `generate_pin` / `main()`. `flutter test` runs with
// cwd = project root.
const _fixtures = 'test/pin_tools/fixtures';

Map<String, dynamic> _load(String name) =>
    jsonDecode(File('$_fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

List<Map<String, dynamic>> _list(Map<String, dynamic> json, String key) =>
    (json[key] as List).cast<Map<String, dynamic>>();

const _ruMaskFormat =
    "Маска должна содержать ровно 8 цифр, например, '24681357'.";
const _ruInputLength =
    'Входная строка должна содержать ровно 20 символов (без пробелов).';
const _ruRangeTemplate =
    'Значение маски на позиции {i} должно быть от 1 до 20.';

/// Expected Dart exception for an exact Python (Russian) message, with the
/// English text taken from the fixture's own translation table.
({String code, String en, int? position}) _expectedFor(
  String ru,
  Map<String, String> ruToEn,
) {
  if (ru == _ruMaskFormat) {
    return (
      code: MaskPinException.codeMaskFormat,
      en: ruToEn[_ruMaskFormat]!,
      position: null,
    );
  }
  if (ru == _ruInputLength) {
    return (
      code: MaskPinException.codeInputLength,
      en: ruToEn[_ruInputLength]!,
      position: null,
    );
  }
  final m =
      RegExp(r'^Значение маски на позиции (\d+) должно быть от 1 до 20\.$')
          .firstMatch(ru);
  if (m != null) {
    final i = m.group(1)!;
    return (
      code: MaskPinException.codeMaskValueRange,
      en: ruToEn[_ruRangeTemplate]!.replaceAll('{i}', i),
      position: int.parse(i),
    );
  }
  throw StateError('Unmapped Python message: $ru');
}

Matcher _throwsMask(({String code, String en, int? position}) x, String ru) =>
    throwsA(
      isA<MaskPinException>()
          .having((e) => e.code, 'code', x.code)
          .having((e) => e.message, 'message', x.en)
          .having((e) => e.messageRu, 'messageRu', ru)
          .having((e) => e.position, 'position', x.position)
          .having((e) => e.toString(), 'toString()', x.en),
    );

Matcher _throwsCode(String code) =>
    throwsA(isA<MaskPinException>().having((e) => e.code, 'code', code));

void main() {
  final vectors = _load('pass_pin.json');
  final errors = _load('pass_pin_errors.json');
  final bulk = _load('pass_pin_bulk.json');
  final ruToEn =
      ((errors['meta'] as Map)['messages_ru_en'] as Map).cast<String, String>();

  group('maskPin — pass_pin.json vectors', () {
    final list = _list(vectors, 'vectors');

    test('fixture is complete (51 vectors, unique ids)', () {
      expect(list, hasLength(vectors['count'] as int));
      expect(list, hasLength(51));
      expect(list.map((v) => v['id']).toSet(), hasLength(list.length));
    });

    test('Python whitespace list in the fixture equals pythonWhitespace', () {
      final cps =
          ((vectors['meta'] as Map)['python_whitespace_codepoints'] as List)
              .map((s) => int.parse((s as String).substring(2), radix: 16))
              .toSet();
      expect(cps, pythonWhitespace);
    });

    for (final v in list) {
      final mask = v['mask'] as String;
      final input = v['input'] as String;
      final expected = v['expected'] as String;

      test('${v['id']} ($mask)', () {
        expect(maskPin(mask, input), expected);
        expect(expected.runes, hasLength(kMaskLength));

        // Whitespace removal and code-point counting.
        final normalized = normalizeMaskInput(input);
        expect(normalized, v['input_normalized']);
        expect(input.runes, hasLength(v['input_len_codepoints'] as int));
        expect(
            normalized.runes, hasLength(v['normalized_len_codepoints'] as int));
        expect(maskInputLength(input), v['normalized_len_codepoints']);
        expect(normalized.length, v['normalized_len_utf16']);

        // Walk explanation.
        final positions = maskPinPositions(mask);
        expect(positions, v['positions_0based']);
        expect(positions.map((p) => p + 1).toList(), v['positions_1based']);
        final revisits = maskPinRevisitSteps(mask);
        expect(revisits, v['revisit_steps_0based']);

        // Probe with 20 distinct letters, as the generator did.
        expect(maskPin(mask, v['probe_input'] as String), v['probe_output']);

        // Output = elements at the visited positions, '0' on revisits.
        final elems = normalized.runes.toList();
        final out = expected.runes.toList();
        for (var i = 0; i < kMaskLength; i++) {
          expect(
            out[i],
            revisits.contains(i) ? 0x30 : elems[positions[i]],
            reason: 'step $i',
          );
        }
      });
    }
  });

  group('maskPin — pass_pin_errors.json', () {
    final list = _list(errors, 'errors');

    test('fixture is complete (22 error cases, unique ids)', () {
      expect(list, hasLength(22));
      expect(list.map((e) => e['id']).toSet(), hasLength(list.length));
    });

    test('English messages equal the fixture translations', () {
      expect(
          const MaskPinException.maskFormat().message, ruToEn[_ruMaskFormat]);
      expect(const MaskPinException.maskFormat().messageRu, _ruMaskFormat);
      expect(
        const MaskPinException.inputLength().message,
        ruToEn[_ruInputLength],
      );
      expect(const MaskPinException.inputLength().messageRu, _ruInputLength);
      final range = MaskPinException.maskValueRange(3);
      expect(range.message, ruToEn[_ruRangeTemplate]!.replaceAll('{i}', '3'));
      expect(range.messageRu, _ruRangeTemplate.replaceAll('{i}', '3'));
      expect(range.position, 3);
    });

    for (final e in list) {
      test('${e['id']}', () {
        final mask = (e['mask'] as Map)['value'] as String;
        final input = (e['input'] as Map)['value'] as String;
        final py = e['python'] as Map<String, dynamic>;
        expect(py['ok'], isFalse);
        expect(py['error_type'], 'ValueError');
        final ru = py['message'] as String;
        final x = _expectedFor(ru, ruToEn);
        expect(() => maskPin(mask, input), _throwsMask(x, ru));

        // Code-point / UTF-16 bookkeeping recorded by the generator.
        final mi = e['input'] as Map<String, dynamic>;
        expect(input.runes, hasLength(mi['len_codepoints'] as int));
        expect(input.length, mi['len_utf16']);

        // maskPinPositions reports mask problems independently of input.
        if (x.code == MaskPinException.codeInputLength) {
          if (mask.contains('0')) {
            // e.g. order_input_before_mask_zero: maskPin reports the input
            // first, but the mask on its own is out of range.
            expect(
              () => maskPinPositions(mask),
              _throwsCode(MaskPinException.codeMaskValueRange),
            );
          } else {
            expect(maskPinPositions(mask), hasLength(kMaskLength));
          }
        } else if (x.code == MaskPinException.codeMaskFormat) {
          expect(() => maskPinPositions(mask), _throwsMask(x, ru));
        } else {
          expect(() => maskPinPositions(mask), _throwsMask(x, ru));
          expect(() => maskPinRevisitSteps(mask), _throwsMask(x, ru));
        }
      });
    }
  });

  group('divergence: Python accepts, port decides', () {
    final list = _list(errors, 'python_accepts_but_port_should_decide');

    test('fixture has the 3 documented cases', () {
      expect(
        list.map((e) => e['id']).toSet(),
        {'arabic_indic_mask', 'fullwidth_mask', 'x1c_separated_input'},
      );
    });

    for (final e in list) {
      test('${e['id']}', () {
        final mask = (e['mask'] as Map)['value'] as String;
        final input = (e['input'] as Map)['value'] as String;
        final py = e['python'] as Map<String, dynamic>;
        expect(py['ok'], isTrue);
        if (e['id'] == 'x1c_separated_input') {
          // U+001C is Python whitespace: the port must agree with Python.
          expect(maskPin(mask, input), py['result']);
        } else {
          // Unicode digits in the mask: rejected by the core (ASCII only)…
          expect(
            () => maskPin(mask, input),
            _throwsMask(_expectedFor(_ruMaskFormat, ruToEn), _ruMaskFormat),
          );
          // …but the UI normalizer restores Python's result.
          expect(maskPin(normalizeInputDigits(mask), input), py['result']);
        }
      });
    }
  });

  group('CLI main() flows — pass_pin_errors.json main_flow', () {
    final list = _list(errors, 'main_flow');
    // Ctrl-C / getpass failures: terminal-only paths with no mobile analogue.
    const terminalOnly = {'ctrl_c_on_mask', 'eof_on_mask'};
    const ruDigitsOnly = 'Маска должна содержать только цифры.';

    test('fixture has 10 recorded runs; terminal-only ones are known', () {
      expect(list, hasLength(10));
      final raising = {
        for (final f in list)
          if ((f['answers'] as List).any((a) => '$a'.startsWith('<raise')))
            f['id'] as String,
      };
      expect(raising, terminalOnly);
      for (final f in list.where((f) => terminalOnly.contains(f['id']))) {
        expect(f['exit_code'], 1);
      }
    });

    for (final f in list) {
      if (terminalOnly.contains(f['id'])) continue;
      test('${f['id']}', () {
        final answers = (f['answers'] as List).cast<String>();
        final stdout = f['stdout'] as String;
        // main() strips both answers before use.
        final mask = pythonStrip(answers[0]);
        final input = pythonStrip(answers[1]);

        final ok =
            RegExp(r'Сгенерированный PIN-код: (.+)\n').firstMatch(stdout);
        final err = RegExp(r'Ошибка: (.+)\n').firstMatch(stdout);
        if (ok != null) {
          expect(f['exit_code'], 0);
          expect(maskPin(mask, input), ok.group(1));
        } else {
          expect(f['exit_code'], 1);
          final ru = err!.group(1)!;
          if (ru == ruDigitsOnly) {
            // main()'s isdigit() pre-check; the core rejects the same masks
            // as a format error.
            expect(
              () => maskPin(mask, input),
              _throwsCode(MaskPinException.codeMaskFormat),
            );
          } else {
            expect(
              () => maskPin(mask, input),
              _throwsMask(_expectedFor(ru, ruToEn), ru),
            );
          }
        }
      });
    }
  });

  group('bulk parity — pass_pin_bulk.json (real Python, seeded)', () {
    final cases = _list(bulk, 'cases');

    test('all ${cases.length} cases match Python output or message', () {
      expect(cases, hasLength(bulk['count'] as int));
      var ok = 0;
      final mismatches = <String>[];
      for (final c in cases) {
        String actual;
        try {
          actual = 'o:${maskPin(c['m'] as String, c['i'] as String)}';
        } on MaskPinException catch (e) {
          final x = _expectedFor(e.messageRu, ruToEn);
          expect(e.code, x.code);
          expect(e.message, x.en);
          actual = 'e:${e.messageRu}';
        }
        final expected = c.containsKey('o') ? 'o:${c['o']}' : 'e:${c['e']}';
        if (actual == expected) {
          if (c.containsKey('o')) ok++;
        } else {
          mismatches.add('${jsonEncode(c)} -> $actual');
        }
      }
      expect(mismatches, isEmpty);
      expect(ok, greaterThan(500));
    });
  });

  group('properties', () {
    const probe = 'ABCDEFGHIJKLMNOPQRST';

    test('random masks: probe output reconstructs from positions', () {
      final rnd = Random(20260926);
      for (var n = 0; n < 5000; n++) {
        final mask = String.fromCharCodes(
          List.generate(kMaskLength, (_) => 0x31 + rnd.nextInt(9)),
        );
        final positions = maskPinPositions(mask);
        expect(positions.first, mask.codeUnitAt(0) - 0x31);
        expect(positions.every((p) => p >= 0 && p < kMaskInputLength), isTrue);
        final revisits = maskPinRevisitSteps(mask);
        final out = maskPin(mask, probe);
        for (var i = 0; i < kMaskLength; i++) {
          expect(out[i], revisits.contains(i) ? '0' : probe[positions[i]]);
        }
      }
    });

    test('output is always 8 code points, even for astral input', () {
      final emoji = String.fromCharCodes(
        List.generate(kMaskInputLength, (i) => 0x1F600 + i),
      );
      final out = maskPin('24681357', emoji);
      expect(out.runes, hasLength(kMaskLength));
      expect(out.length, 2 * kMaskLength);
      // 10 emoji = 20 UTF-16 units must be rejected (counted as 10).
      expect(
        () => maskPin('24681357', emoji.substring(0, 20)),
        _throwsCode(MaskPinException.codeInputLength),
      );
    });

    test('revisits emit a literal 0', () {
      expect(maskPin('55555555', probe), 'EJOT0000');
      expect(maskPin('15555111', probe), 'AFKP0BCD');
      expect(maskPinRevisitSteps('55555555'), [4, 5, 6, 7]);
      expect(maskPinRevisitSteps('24681357'), isEmpty);
    });

    test('non-whitespace oddities count as characters (Python parity)', () {
      // Verified against the real generate_pin: U+FEFF / U+200B are not
      // whitespace; a lone surrogate is one code point.
      expect(maskPin('24681357', 'ABCDEFGHIJKLMNOPQRS\uFEFF'), 'BFL\uFEFFADIP');
      expect(maskPin('24681357', 'ABCDEFGHIJKLMNOPQRS\u200B'), 'BFL\u200BADIP');
      expect(maskPin('24681357', 'ABCDEFGHIJKLMNOPQRS\uD800'), 'BFL\uD800ADIP');
      expect(
        maskPin('24681357', 'ABCDEFGHIJKLMNOPQRS\uFEFF \u2028'),
        'BFL\uFEFFADIP',
      );
    });

    test('lone surrogates split by whitespace stay two code points', () {
      // Regression, verified against the real generate_pin (Python 3.14):
      // removing the space must not fuse a lone high and a lone low surrogate
      // into one astral code point (Python keeps len() == 20 here).
      const split = 'abcdefghijklmnopqr\uD83D \uDE00';
      expect(maskInputLength(split), kMaskInputLength);
      expect(maskPin('24681357', split), 'bfl\uDE00adip');
      expect(
        maskPin('72295232', 'jiabeiefgicidj\uD83D\n\uDE00fjfh'),
        'egche0ii',
      );
      // 21 code points in Python -> rejected, although the joined Dart
      // string reads as 20 runes.
      const long = 'abcdefghijklmnopqrs\uD83D\u3000\uDE00';
      expect(maskInputLength(long), 21);
      expect(normalizeMaskInput(long).runes, hasLength(20));
      expect(
        () => maskPin('24681357', long),
        _throwsCode(MaskPinException.codeInputLength),
      );
      // The joined string is still UTF-16-identical to Python's join.
      expect(normalizeMaskInput(split), 'abcdefghijklmnopqr😀');
      // A real surrogate pair (emoji) is one code point.
      expect(maskInputLength('\u{1F600} ' * 20), 20);
    });

    test('mask is not stripped and must be ASCII digits', () {
      for (final bad in [' 24681357', '24681357 ', '2468135٧', '']) {
        expect(
          () => maskPin(bad, probe),
          _throwsCode(MaskPinException.codeMaskFormat),
        );
        expect(
          () => maskPinPositions(bad),
          _throwsCode(MaskPinException.codeMaskFormat),
        );
      }
    });

    test('check order: format, then input length, then value range', () {
      expect(() => maskPin('1234567', 'x'), _throwsCode('MASK_FORMAT'));
      expect(() => maskPin('10345678', 'x'), _throwsCode('INPUT_LENGTH'));
      expect(() => maskPin('10345678', probe), _throwsCode('MASK_VALUE_RANGE'));
      expect(
        () => maskPinPositions('12345670'),
        throwsA(isA<MaskPinException>().having((e) => e.position, 'pos', 8)),
      );
    });

    test('runs in a background isolate (no Flutter dependency)', () async {
      final out = await Isolate.run(
        () => maskPin('24681357', '73015946288150347629'),
      );
      expect(out, '39197124');
    });
  });
}
