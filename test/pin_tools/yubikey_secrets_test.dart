import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:vault_approver/pin_tools/yubikey_secrets.dart';

// Vectors generated from yubikey-fleet/bin/yk-batch-secrets.py (SYNTHETIC
// master keys and serials only).
const _fixtures = 'test/pin_tools/fixtures';

Map<String, dynamic> _loadJson(String name) =>
    jsonDecode(File('$_fixtures/$name').readAsStringSync())
        as Map<String, dynamic>;

Uint8List _hex(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Matcher _throwsYk(String code) =>
    throwsA(isA<YkException>().having((e) => e.code, 'code', code));

Uint8List _hmac(List<int> key, List<int> msg) =>
    (HMac(SHA256Digest(), 64)..init(KeyParameter(Uint8List.fromList(key))))
        .process(Uint8List.fromList(msg));

const _allPhases = {YkPhase.openpgp, YkPhase.fido2, YkPhase.oath, YkPhase.otp};

/// Top-level so the isolate closure captures nothing but [master].
Future<String> _deriveInIsolate(Uint8List master) => Isolate.run(
    () => ykDerive(master: master, serial: '12345678', field: '00'));

/// Records every `nextInt` bound so the tests can prove ykRandom asks for
/// exactly `alphabet.length` (unbiased choice, like `secrets.choice`). Passed
/// as `nextIntForTest: rng.nextInt` — the test hook takes a function, never a
/// [Random].
class _RecordingRandom {
  final Random _inner = Random(20260926);
  final bounds = <int>[];
  final results = <int>[];

  int nextInt(int max) {
    bounds.add(max);
    final r = _inner.nextInt(max);
    results.add(r);
    return r;
  }
}

void main() {
  final derived = _loadJson('yubikey_derived.json');
  final edge = _loadJson('yubikey_edge.json');
  final vectors = (derived['vectors'] as List).cast<Map<String, dynamic>>();
  final masters = (derived['masters'] as List).cast<Map<String, dynamic>>();
  final scenarios =
      (derived['cli_scenarios'] as List).cast<Map<String, dynamic>>();
  Map<String, dynamic> scenario(String id) =>
      scenarios.firstWhere((s) => s['id'] == id);
  String scenarioCsv(String id) =>
      ((scenario(id)['bitwarden'] as Map)['csv'] as Map)['raw'] as String;
  Uint8List masterIkm(String id) =>
      _hex(masters.firstWhere((m) => m['id'] == id)['ikm_hex'] as String);

  test('fixtures loaded', () {
    expect(vectors, hasLength(285));
    expect(masters, hasLength(6));
  });

  test('yubikey fixtures carry no absolute local paths', () {
    final files = Directory(_fixtures)
        .listSync()
        .whereType<File>()
        .where((f) => f.uri.pathSegments.last.startsWith('yubikey'))
        .toList();
    // yubikey_derived.json, yubikey_edge.json, yubikey_export_sample.csv and
    // yubikey_ledger.json (Ledger → YubiKey, generated from pin24.py).
    expect(files, hasLength(4));
    for (final f in files) {
      expect(f.readAsStringSync(),
          isNot(matches(RegExp('/(Users|home|private|tmp)/'))),
          reason: f.path);
    }
    // source_sha256 pins the exact script; the path is repo-relative.
    expect(derived['source'], 'yubikey-fleet/bin/yk-batch-secrets.py');
  });

  group('FIELDS table', () {
    test('matches the script: order, names, bounds, alphabets', () {
      final f = (derived['fields'] as Map).cast<String, dynamic>();
      expect(ykFields.keys.toList(), f.keys.toList());
      expect(ykFields.keys.toList(),
          ['00', '14', '23', '24', '25', '34', '41', '45', '46']);
      for (final e in f.entries) {
        final spec = ykFields[e.key]!;
        final want = e.value as Map<String, dynamic>;
        expect(spec.number, e.key);
        expect(spec.name, want['name']);
        expect(spec.min, want['min']);
        expect(spec.max, want['max']);
        expect(spec.alphabet, want['alphabet']);
        expect(
            ykDefaultLength(e.key, YkMode.random), want['default_len_random']);
        expect(ykDefaultLength(e.key, YkMode.derived),
            want['default_len_derived']);
      }
    });

    test('ykDefaultLength rejects unknown fields', () {
      for (final f in ['0', '99', '00 ', 'piv.pin', '']) {
        expect(() => ykDefaultLength(f, YkMode.random),
            _throwsYk(YkException.unknownField));
      }
    });

    test('ykNeededFields for every phase subset', () {
      const all = YkPhase.values;
      for (var mask = 0; mask < 1 << all.length; mask++) {
        final phases = {
          for (var i = 0; i < all.length; i++)
            if (mask & (1 << i) != 0) all[i],
        };
        // The script's `need` list, built the same way.
        final want = ['00', '14'];
        if (phases.contains(YkPhase.openpgp)) want.addAll(['23', '24', '25']);
        if (phases.contains(YkPhase.fido2)) want.add('34');
        if (phases.contains(YkPhase.oath)) want.add('41');
        if (phases.contains(YkPhase.otp)) want.addAll(['45', '46']);
        final got = ykNeededFields(phases);
        expect(got, want, reason: '$phases');
        expect(got, [...got]..sort());
      }
    });
  });

  group('master key (bytes.strip, >= 32)', () {
    test('fixture key files normalise to their effective key', () {
      for (final m in masters) {
        final got = ykNormalizeMasterKey(_hex(m['file_bytes_hex'] as String));
        expect(_toHex(got), m['ikm_hex'], reason: m['id'] as String);
        expect(got.length, m['ikm_len']);
      }
    });

    test('edge cases match Python bytes.strip()', () {
      final cases = (edge['normalize'] as List).cast<Map<String, dynamic>>();
      expect(cases, hasLength(15));
      for (final c in cases) {
        final raw = _hex(c['raw_hex'] as String);
        if (c['error'] == true) {
          expect(() => ykNormalizeMasterKey(raw),
              _throwsYk(YkException.masterTooShort),
              reason: c['raw_hex'] as String);
        } else {
          expect(_toHex(ykNormalizeMasterKey(raw)), c['ikm_hex'],
              reason: c['raw_hex'] as String);
        }
      }
    });

    test('S7: 31-byte key file is refused', () {
      final raw = utf8.encode('only-31-bytes-synthetic-key-xyz\n');
      expect(() => ykNormalizeMasterKey(raw),
          _throwsYk(YkException.masterTooShort));
    });

    test('returns an independent copy and leaves the input alone', () {
      final raw = Uint8List.fromList([0x20, ...List.filled(40, 0x41), 0x0a]);
      final before = Uint8List.fromList(raw);
      final key = ykNormalizeMasterKey(raw);
      expect(raw, before);
      key[0] = 0;
      expect(raw[1], 0x41);
      expect(key, hasLength(40));
    });

    test('non-byte input is an ArgumentError', () {
      expect(() => ykNormalizeMasterKey([...List.filled(32, 65), 256]),
          throwsArgumentError);
      expect(() => ykNormalizeMasterKey([-1, ...List.filled(32, 65)]),
          throwsArgumentError);
    });
  });

  group('derived vectors (${vectors.length})', () {
    for (final v in vectors) {
      final field = v['field'] as String;
      final serial = v['serial'] as String;
      final length = v['length'] as int;
      test('${v['kind']} ${v['master_id']} $serial/$field L=$length', () {
        final master = _hex(v['ikm_hex'] as String);
        final masterBefore = Uint8List.fromList(master);

        final t = ykDeriveTrace(
            master: master, serial: serial, field: field, length: length);
        expect(utf8.decode(t.info), v['info_utf8']);
        expect(_toHex(t.info), v['info_hex']);
        expect(t.hmacBlocks, v['hmac_blocks']);
        expect(_toHex(t.okm), v['okm_hex']);
        expect(t.bytesConsumed, v['bytes_consumed']);
        expect(t.bytesRejected, v['bytes_rejected']);
        expect(t.value, v['value']);
        t.wipe();
        expect(t.okm.every((b) => b == 0), isTrue);

        expect(
            ykDerive(
                master: master, serial: serial, field: field, length: length),
            v['value']);
        if (v['kind'] == 'default_length') {
          expect(ykDerive(master: master, serial: serial, field: field),
              v['value']);
        }
        expect(master, masterBefore, reason: 'master must not be modified');

        // The sampler alone, fed the recorded OKM.
        final s = ykSampleOkm(
            _hex(v['okm_hex'] as String), v['alphabet'] as String, length);
        expect(s.value, v['value']);
        expect(s.bytesConsumed, v['bytes_consumed']);
        expect(s.bytesRejected, v['bytes_rejected']);

        expect(ykSha256Prefix6(v['value'] as String), v['sha256_6']);
        expect(ykCheckValue(field, v['value'] as String), isEmpty);
      });
    }

    test('coverage: rejections, second blocks, every master and field', () {
      expect(vectors.where((v) => (v['bytes_rejected'] as int) > 0).length,
          greaterThanOrEqualTo(4));
      expect(vectors.where((v) => v['hmac_blocks'] == 2), hasLength(2));
      expect(vectors.map((v) => v['master_id']).toSet(), hasLength(6));
      expect(vectors.map((v) => v['field']).toSet(), ykFields.keys.toSet());
    });
  });

  group('construction is raw HMAC blocks, not RFC 5869 HKDF', () {
    // Mirrors the fixture's construction_checks with an independent HMAC.
    final ikm = masterIkm('MK_A_ascii44');
    final info = utf8.encode('yk-fleet/12345678/00');
    final t =
        ykDeriveTrace(master: ikm, serial: '12345678', field: '41', length: 32);
    final info41 = utf8.encode('yk-fleet/12345678/41');

    test('block 1 == HKDF-Expand(PRK = master, info) T(1)', () {
      final t1 = _hmac(ikm, [...info41, 1]);
      expect(t.okm.sublist(0, 32), t1);
      expect(
          ykDeriveTrace(master: ikm, serial: '12345678', field: '00')
              .okm
              .sublist(0, 32),
          _hmac(ikm, [...info, 1]));
    });

    test('block 2 is HMAC(master, info || 0x02), not chained T(2)', () {
      final t1 = _hmac(ikm, [...info41, 1]);
      final chained = _hmac(ikm, [...t1, ...info41, 2]);
      final raw = _hmac(ikm, [...info41, 2]);
      expect(t.okm.sublist(32, 64), raw);
      expect(t.okm.sublist(32, 64), isNot(chained));
    });

    test('no Extract step', () {
      final prk = _hmac(Uint8List(32), ikm); // Extract with zero salt
      expect(t.okm.sublist(0, 32), isNot(_hmac(prk, [...info41, 1])));
      final checks =
          (derived['construction_checks'] as List).cast<Map<String, dynamic>>();
      expect(checks.map((c) => c['result']), [true, false, false, false]);
    });
  });

  group('derive argument handling', () {
    final ikm = masterIkm('MK_A_ascii44');

    test('length outside the field bounds', () {
      for (final e in ykFields.entries) {
        expect(
            () => ykDerive(
                master: ikm,
                serial: '1',
                field: e.key,
                length: e.value.min - 1),
            _throwsYk(YkException.lengthOutOfRange));
        expect(
            () => ykDerive(
                master: ikm,
                serial: '1',
                field: e.key,
                length: e.value.max + 1),
            _throwsYk(YkException.lengthOutOfRange));
      }
    });

    test('unknown field', () {
      expect(() => ykDerive(master: ikm, serial: '1', field: '99'),
          _throwsYk(YkException.unknownField));
      expect(() => ykDerive(master: ikm, serial: '1', field: '0'),
          _throwsYk(YkException.unknownField));
    });

    test('short master / unnormalised master', () {
      expect(
          () => ykDerive(
              master: Uint8List.fromList(List.filled(31, 65)),
              serial: '1',
              field: '00'),
          _throwsYk(YkException.masterTooShort));
      expect(
          () => ykDerive(
              master: Uint8List.fromList([...ikm, 0x0a]),
              serial: '1',
              field: '00'),
          throwsArgumentError);
      expect(
          () => ykDerive(
              master: Uint8List.fromList([0x20, ...ikm]),
              serial: '1',
              field: '00'),
          throwsArgumentError);
    });

    test('serial is str.strip()ped and otherwise verbatim', () {
      final want = vectors.firstWhere((v) =>
          v['master_id'] == 'MK_A_ascii44' &&
          v['serial'] == '12345678' &&
          v['field'] == '00' &&
          v['kind'] == 'default_length')['value'];
      for (final s in ['　 12345678\n', '\x1c12345678\x1f', '12345678']) {
        expect(ykDerive(master: ikm, serial: s, field: '00'), want);
      }
      expect(ykDerive(master: ikm, serial: '0012389', field: '00'),
          isNot(ykDerive(master: ikm, serial: '12389', field: '00')));
    });

    test('empty or unencodable serial', () {
      for (final s in ['', '   ', '\x1c ']) {
        expect(() => ykDerive(master: ikm, serial: s, field: '00'),
            _throwsYk(YkException.serialInvalid));
      }
      expect(() => ykDerive(master: ikm, serial: '12\uD800', field: '00'),
          _throwsYk(YkException.serialInvalid));
    });

    test('runs inside Isolate.run (no Flutter dependency)', () async {
      expect(await _deriveInIsolate(ikm), '77747579');
      final src = File('lib/pin_tools/yubikey_secrets.dart').readAsStringSync();
      expect(src.contains('package:flutter'), isFalse);
    });
  });

  group('rejection sampler', () {
    test('OKM exhausted is a hard error', () {
      expect(() => ykSampleOkm(List.filled(32, 250), '0123456789', 8),
          _throwsYk(YkException.okmExhausted));
      expect(
          () => ykSampleOkm([...List.filled(25, 248), ...List.filled(7, 0)],
              ykFields['23']!.alphabet, 8),
          _throwsYk(YkException.okmExhausted));
    });

    test('limits: 250 digits, 248 alphanumeric, hex never rejects', () {
      final s = ykSampleOkm([249, 250, 255, 0], '0123456789', 2);
      expect(s.value, '90');
      expect(s.bytesConsumed, 4);
      expect(s.bytesRejected, 2);
      final a = ykSampleOkm([247, 248, 61, 62], ykFields['41']!.alphabet, 3);
      expect(a.value, '99a');
      expect(a.bytesRejected, 1);
      final h = ykSampleOkm([255, 0, 0x7a], '0123456789abcdef', 3);
      expect(h.value, 'f0a');
      expect(h.bytesRejected, 0);
    });

    test('stops at length without reading further', () {
      final s = ykSampleOkm([1, 2, 3, 255, 255], '0123456789', 3);
      expect(s.value, '123');
      expect(s.bytesConsumed, 3);
    });

    test('non-byte input', () {
      expect(() => ykSampleOkm([300], '0123456789', 1), throwsArgumentError);
      expect(() => ykSampleOkm([-1], '0123456789', 1), throwsArgumentError);
    });
  });

  group('OTP access code from serial', () {
    test('fixture cases', () {
      for (final c in (derived['otp_from_serial'] as List)
          .cast<Map<String, dynamic>>()) {
        expect(ykOtpFromSerial(c['serial'] as String), c['code']);
      }
    });

    test('Python int() edge cases', () {
      final cases = (edge['otp_format'] as List).cast<Map<String, dynamic>>();
      expect(cases, hasLength(62));
      for (final c in cases) {
        final input = c['input'] as String;
        final reason = jsonEncode(input.length > 40
            ? '${input.substring(0, 20)}…(${input.length})'
            : input);
        if (c['error'] == true) {
          expect(() => ykOtpFromSerial(input),
              _throwsYk(YkException.serialInvalid),
              reason: reason);
        } else {
          expect(ykOtpFromSerial(input), c['code'], reason: reason);
        }
      }
      expect(edge['int_max_str_digits'], 4300);
    });

    test('script path: str.strip() then int()', () {
      for (final c
          in (edge['otp_script'] as List).cast<Map<String, dynamic>>()) {
        final input = c['input'] as String;
        YkKeySecrets resolve() => ykResolveKey(
            serial: input,
            phases: {YkPhase.otp},
            mode: YkMode.random,
            otpFromSerial: true);
        if (c['error'] == true) {
          expect(resolve, _throwsYk(YkException.serialInvalid),
              reason: jsonEncode(input));
        } else {
          final k = resolve();
          expect(k.serial, c['stripped']);
          expect(k.values['45'], c['code']);
          expect(k.values['46'], c['code']);
        }
      }
    });

    test('lone surrogate', () {
      expect(() => ykOtpFromSerial('12\uDC00'),
          _throwsYk(YkException.serialInvalid));
    });

    test('every code point: int(chr(cp)) parity with Python unicodedata', () {
      final zeros = (edge['decimal_zeros'] as List).cast<int>();
      expect(zeros, hasLength(76));
      expect(edge['unicode_version'], '16.0.0');
      var accepted = 0;
      for (var cp = 0; cp <= 0x10FFFF; cp++) {
        if (cp >= 0xD800 && cp <= 0xDFFF) continue;
        final zero = zeros.where((z) => cp >= z && cp <= z + 9).firstOrNull;
        final s = String.fromCharCode(cp);
        if (zero == null) {
          expect(() => ykOtpFromSerial(s), _throwsYk(YkException.serialInvalid),
              reason: 'U+${cp.toRadixString(16)}');
        } else {
          accepted++;
          expect(ykOtpFromSerial(s), '${cp - zero}'.padLeft(12, '0'),
              reason: 'U+${cp.toRadixString(16)}');
        }
      }
      expect(accepted, 760);
    });
  });

  group('--check', () {
    test('edge values agree with the script check', () {
      final cases = (edge['check_value'] as List).cast<Map<String, dynamic>>();
      expect(cases, hasLength(41));
      for (final c in cases) {
        final field = c['field'] as String;
        final value = c['value'] as String;
        final problems = ykValidateValue(field, value);
        final kinds = problems.map((p) => p.kind).toList();
        expect(
            kinds,
            [
              if (c['length_ok'] != true) YkValueProblemKind.length,
              if (c['chars_ok'] != true) YkValueProblemKind.alphabet,
            ],
            reason: '$field ${jsonEncode(value)}');
        for (final p in problems) {
          expect(p.length, c['len']);
        }
        expect(ykCheckValue(field, value), hasLength(problems.length));
      }
    });

    test('S7 manual values out of bounds: script messages', () {
      expect(ykCheckValue('00', '123456789'),
          ['field 00 (piv.pin): length 9, allowed 6..8']);
      expect(ykCheckValue('23', 'has space!'),
          ['field 23 (openpgp.user-pin): invalid characters']);
      expect(ykCheckValue('45', ''),
          ['field 45 (otp.slot1.access-code): length 0, allowed 12..12']);
    });

    test('messages never echo the value', () {
      for (final p in ykCheckValue('41', 'SECRET,VALUE!')) {
        expect(p.contains('SECRET'), isFalse);
      }
    });

    test('S7 13-digit serial: OTP code resolves, then fails the check', () {
      final k = ykResolveKey(
          serial: '1234567890123',
          phases: _allPhases,
          mode: YkMode.derived,
          master: masterIkm('MK_A_ascii44'),
          otpFromSerial: true);
      expect(k.values['45'], '1234567890123');
      expect(ykCheckValue('45', k.values['45']!),
          ['field 45 (otp.slot1.access-code): length 13, allowed 12..12']);
      expect(ykCheckValue('46', k.values['46']!), hasLength(1));
      expect(() => ykBitwardenCsv([k]), _throwsYk(YkException.valueInvalid));
    });

    test('unknown field', () {
      expect(
          () => ykCheckValue('99', '1'), _throwsYk(YkException.unknownField));
    });
  });

  group('resolve + --bitwarden export', () {
    // Inputs of scratchpad manifests/sample.yaml, transcribed by hand:
    //   secrets: derived, master_key_file: keys/synthetic-A.key
    //   phases: all true; options.otp_access_from_serial: true
    //   keys: "12345678", "99999999", "0012389" (all double-quoted)
    test('sample.yaml export is byte-identical to the script CSV', () {
      final keyFile =
          utf8.encode('SYNTHETIC-TEST-MASTER-KEY-A-0123456789abcdef\n');
      final master = ykNormalizeMasterKey(keyFile);
      final keys = [
        for (final serial in ['12345678', '99999999', '0012389'])
          ykResolveKey(
              serial: serial,
              phases: _allPhases,
              mode: YkMode.derived,
              master: master,
              otpFromSerial: true),
      ];
      final csv = ykBitwardenCsv(keys);
      final want =
          File('$_fixtures/yubikey_export_sample.csv').readAsBytesSync();
      expect(utf8.encode(csv), want);
      expect(csv, scenarioCsv('S1_sample_derived_all_phases'));
      expect('\n'.allMatches(csv), hasLength(28));
    });

    test('S2: OTP codes derived when not from serial', () {
      final k = ykResolveKey(
          serial: '12345678',
          phases: _allPhases,
          mode: YkMode.derived,
          master: masterIkm('MK_A_ascii44'));
      expect(
          ykBitwardenCsv([k]), scenarioCsv('S2_derived_otp_not_from_serial'));
      expect(k.values['45'], isNot(k.values['46']));
    });

    test('S3: phase subset, whitespace-padded master file', () {
      final keyFile = _hex(
          masters.firstWhere((m) => m['id'] == 'MK_E_padded')['file_bytes_hex']
              as String);
      final k = ykResolveKey(
          serial: '5000001',
          phases: {YkPhase.fido2},
          mode: YkMode.derived,
          master: ykNormalizeMasterKey(keyFile),
          otpFromSerial: true);
      expect(k.values.keys, ['00', '14', '34']);
      expect(ykBitwardenCsv([k]),
          scenarioCsv('S3_derived_phase_subset_padded_master'));
    });

    test('S4: manual beats derived; OTP-from-serial beats manual', () {
      final k = ykResolveKey(
          serial: '12345678',
          phases: _allPhases,
          mode: YkMode.derived,
          master: masterIkm('MK_A_ascii44'),
          otpFromSerial: true,
          manual: const {'00': '11223344', '45': 'aaaaaaaaaaaa'});
      expect(ykBitwardenCsv([k]),
          scenarioCsv('S4_derived_manual_override_and_otp_precedence'));
    });

    test('S5: serials as Ruby YAML 1.1 typed them (0012345 -> 5349)', () {
      final keys = [
        for (final serial in ['5349', '38000001'])
          ykResolveKey(
              serial: serial,
              phases: _allPhases,
              mode: YkMode.derived,
              master: masterIkm('MK_A_ascii44'),
              otpFromSerial: true),
      ];
      expect(ykBitwardenCsv(keys),
          scenarioCsv('S5_unquoted_serials_yaml11_octal'));
    });

    test('S6: random-mode export has the script\'s shape (values not compared)',
        () {
      // The script's S6 values are secrets.choice output for synthetic
      // serials, so only the shape is reproducible (critic #1): header, row
      // order, serial and field columns, value lengths, alphabets; 45/46 are
      // derived from the serial and therefore comparable.
      final s6 = scenario('S6_random_check_fill_export');
      final csvDoc = (s6['bitwarden'] as Map)['csv'] as Map;
      expect(csvDoc['mode_octal'], '0o600');
      final rows = [
        for (final r in csvDoc['rows'] as List) (r as List).cast<String>(),
      ];
      final body = rows.sublist(1);
      expect(body, hasLength(27));
      final serials = {for (final r in body) r[1]}.toList();
      expect(serials, ['12345678', '99999999', '0012389']);

      final keys = [
        for (final serial in serials)
          ykResolveKey(
              serial: serial,
              phases: _allPhases,
              mode: YkMode.random,
              otpFromSerial: true),
      ];
      final csv = ykBitwardenCsv(keys);
      expect(csv.endsWith('\n'), isTrue);
      final lines = const LineSplitter().convert(csv);
      expect(lines.first, rows.first.join(','));
      expect(lines, hasLength(rows.length));
      for (var i = 0; i < body.length; i++) {
        final want = body[i];
        final got = lines[i + 1].split(',');
        expect(got, hasLength(4));
        expect(got.sublist(0, 3), want.sublist(0, 3));
        final field = want[2].substring(0, 2);
        expect(got[3].length, want[3].length, reason: want[2]);
        expect(ykCheckValue(field, got[3]), isEmpty, reason: want[2]);
        expect(ykCheckValue(field, want[3]), isEmpty, reason: want[2]);
        if (field == '45' || field == '46') expect(got[3], want[3]);
      }
    });

    test('S6: unfilled random manifest resolves to max-length values', () {
      final rng = _RecordingRandom();
      final k = ykResolveKey(
          serial: '12345678',
          phases: _allPhases,
          mode: YkMode.random,
          otpFromSerial: true,
          nextIntForTest: rng.nextInt);
      for (final e in k.values.entries) {
        final spec = ykFields[e.key]!;
        if (e.key == '45' || e.key == '46') {
          expect(e.value, '000012345678');
        } else {
          expect(e.value.length, spec.max);
        }
        expect(ykCheckValue(e.key, e.value), isEmpty);
      }
      expect(rng.bounds.length, 8 + 8 + 16 + 16 + 24 + 16 + 32);
    });
  });

  group('ykResolveKey precedence and validation', () {
    final ikm = masterIkm('MK_A_ascii44');

    test('OTP-from-serial only applies with the otp phase', () {
      final k = ykResolveKey(
          serial: 'not-a-number',
          phases: {YkPhase.openpgp},
          mode: YkMode.derived,
          master: ikm,
          otpFromSerial: true);
      expect(k.values.keys, ['00', '14', '23', '24', '25']);
      expect(
          () => ykResolveKey(
              serial: 'not-a-number',
              phases: {YkPhase.otp},
              mode: YkMode.derived,
              master: ikm,
              otpFromSerial: true),
          _throwsYk(YkException.serialInvalid));
    });

    test('empty manual value falls through; unneeded manual is ignored', () {
      final k = ykResolveKey(
          serial: '12345678',
          phases: const {},
          mode: YkMode.derived,
          master: ikm,
          manual: const {'00': '', '41': 'ignored-field-value', '99': 'x'});
      expect(k.values, {'00': '77747579', '14': '53556731'});
    });

    test('derived mode needs a master, checked even if every field is manual',
        () {
      expect(
          () =>
              ykResolveKey(serial: '1', phases: const {}, mode: YkMode.derived),
          throwsArgumentError);
      expect(
          () => ykResolveKey(
              serial: '1',
              phases: const {},
              mode: YkMode.derived,
              master: Uint8List(31),
              manual: const {'00': '123456', '14': '654321'}),
          _throwsYk(YkException.masterTooShort));
    });

    test('master is checked before the serial, like the script', () {
      // The script reads and checks the master once, before any key, so
      // with both bad it stops on the master (verified against its main()).
      final short = Uint8List.fromList(List.filled(31, 0x41));
      final padded = Uint8List.fromList([0x20, ...List.filled(40, 0x41)]);
      for (final s in ['', ' ', ' \t', '12\uD800']) {
        expect(
            () => ykResolveKey(
                serial: s,
                phases: const {},
                mode: YkMode.derived,
                master: short),
            _throwsYk(YkException.masterTooShort),
            reason: '${s.codeUnits}');
        expect(
            () =>
                ykResolveKey(serial: s, phases: const {}, mode: YkMode.derived),
            throwsArgumentError,
            reason: '${s.codeUnits}');
        expect(
            () => ykResolveKey(
                serial: s,
                phases: const {},
                mode: YkMode.derived,
                master: padded),
            throwsArgumentError,
            reason: '${s.codeUnits}');
        // Master fine: now the serial is what fails.
        expect(
            () => ykResolveKey(
                serial: s, phases: const {}, mode: YkMode.derived, master: ikm),
            _throwsYk(YkException.serialInvalid),
            reason: '${s.codeUnits}');
      }
    });

    test('random mode draws from Random.secure unless the hook is given', () {
      final a =
          ykResolveKey(serial: '1', phases: _allPhases, mode: YkMode.random);
      final b =
          ykResolveKey(serial: '1', phases: _allPhases, mode: YkMode.random);
      // 62^32 possible oath passwords: equal only if the source is fixed.
      expect(a.values['41'], isNot(b.values['41']));
      // Only an explicit test hook makes draws repeatable.
      expect(ykRandom('00', nextIntForTest: Random(1).nextInt),
          ykRandom('00', nextIntForTest: Random(1).nextInt));
    });

    test('random mode ignores the master', () {
      final k = ykResolveKey(
          serial: '1',
          phases: const {},
          mode: YkMode.random,
          master: Uint8List(1));
      expect(k.values.keys, ['00', '14']);
    });

    test('serial is stripped; empty serial refused', () {
      final k = ykResolveKey(
          serial: ' 12345678 ',
          phases: const {},
          mode: YkMode.derived,
          master: ikm);
      expect(k.serial, '12345678');
      expect(k.values['00'], '77747579');
      expect(
          () => ykResolveKey(
              serial: ' \t', phases: const {}, mode: YkMode.random),
          _throwsYk(YkException.serialInvalid));
    });

    test('values follow ykNeededFields order and are unmodifiable', () {
      final k = ykResolveKey(
          serial: '1', phases: _allPhases, mode: YkMode.derived, master: ikm);
      expect(k.values.keys.toList(), ykNeededFields(_allPhases));
      expect(() => k.values['00'] = 'x', throwsUnsupportedError);
      expect(k.toString().contains(k.values['00']!), isFalse);
    });
  });

  group('ykBitwardenCsv guards', () {
    YkKeySecrets key(String serial, Map<String, String> values) =>
        YkKeySecrets(serial: serial, values: values);

    test('duplicate serials collapse like a Python dict', () {
      final csv = ykBitwardenCsv([
        key('1', {'00': '111111', '14': '111111'}),
        key('2', {'00': '222222', '14': '222222'}),
        key('1', {'00': '333333', '14': '333333'}),
      ]);
      expect(
          csv,
          'folder,name,field,value\n'
          'yk-fleet,1,00 piv.pin,333333\n'
          'yk-fleet,1,14 piv.puk,333333\n'
          'yk-fleet,2,00 piv.pin,222222\n'
          'yk-fleet,2,14 piv.puk,222222\n');
    });

    test('fields are sorted by number', () {
      final csv = ykBitwardenCsv([
        key('7', {'46': 'aaaaaaaaaaaa', '14': '123456', '00': '654321'}),
      ]);
      expect(
          csv,
          'folder,name,field,value\n'
          'yk-fleet,7,00 piv.pin,654321\n'
          'yk-fleet,7,14 piv.puk,123456\n'
          'yk-fleet,7,46 otp.slot2.access-code,aaaaaaaaaaaa\n');
    });

    test('serials the unquoted CSV cannot carry are refused', () {
      for (final s in ['1,2', '1"2', '1\n2', '1\r2', '', ' 1', '1　']) {
        expect(
            () => ykBitwardenCsv([
                  key(s, {'00': '123456'})
                ]),
            _throwsYk(YkException.serialInvalid),
            reason: jsonEncode(s));
      }
    });

    test('serials a spreadsheet would run as a formula are refused', () {
      for (final s in ['=1+2', '+12_345', '-5', '-0012389', '@SUM(A1)', '+']) {
        expect(
            () => ykBitwardenCsv([
                  key('1', {'00': '123456'}),
                  key(s, {'00': '123456'}),
                ]),
            _throwsYk(YkException.serialInvalid),
            reason: s);
      }
      // Serial guard first: an invalid value does not change the code.
      expect(
          () => ykBitwardenCsv([
                key('=1', {'00': 'short'})
              ]),
          _throwsYk(YkException.serialInvalid));
      // Not leading: exported unchanged.
      expect(
          ykBitwardenCsv([
            for (final s in ['1-2', '1+2', '12=3', 'a@b', '5-'])
              key(s, {'00': '123456'}),
          ]),
          'folder,name,field,value\n'
          'yk-fleet,1-2,00 piv.pin,123456\n'
          'yk-fleet,1+2,00 piv.pin,123456\n'
          'yk-fleet,12=3,00 piv.pin,123456\n'
          'yk-fleet,a@b,00 piv.pin,123456\n'
          'yk-fleet,5-,00 piv.pin,123456\n');
    });

    test('formula serials still derive like the script; only export refuses',
        () {
      final master = Uint8List.fromList(List.filled(40, 0x41));
      // The script writes `yk-fleet,=1+2,00 piv.pin,79377431` for this key.
      final k = ykResolveKey(
          serial: '=1+2',
          phases: const {},
          mode: YkMode.derived,
          master: master);
      expect(k.values['00'], '79377431');
      expect(() => ykBitwardenCsv([k]), _throwsYk(YkException.serialInvalid));
      // `int('+12_345')` is valid, so OTP-from-serial resolves too.
      final p = ykResolveKey(
          serial: '+12_345',
          phases: {YkPhase.otp},
          mode: YkMode.derived,
          master: master,
          otpFromSerial: true);
      expect(p.values['45'], '000000012345');
      expect(() => ykBitwardenCsv([p]), _throwsYk(YkException.serialInvalid));
    });

    test('invalid values abort the whole export without echoing them', () {
      for (final v in ['abc,defgh', 'abcdefg"h', 'abcd\nefgh', 'short']) {
        expect(
            () => ykBitwardenCsv([
                  key('1', {'00': '123456'}),
                  key('2', {'23': v}),
                ]),
            throwsA(isA<YkException>()
                .having((e) => e.code, 'code', YkException.valueInvalid)
                .having((e) => e.message.contains(v), 'echoes value', false)));
      }
    });

    test('unknown field / no keys', () {
      expect(
          () => ykBitwardenCsv([
                key('1', {'99': '1'})
              ]),
          _throwsYk(YkException.unknownField));
      expect(() => ykBitwardenCsv(const []), throwsArgumentError);
    });
  });

  group('random mode', () {
    test('asks nextInt(alphabet.length) per character', () {
      for (final e in ykFields.entries) {
        final rng = _RecordingRandom();
        final v = ykRandom(e.key, nextIntForTest: rng.nextInt);
        expect(v.length, e.value.max);
        expect(rng.bounds, List.filled(e.value.max, e.value.alphabet.length));
        expect(v, rng.results.map((i) => e.value.alphabet[i]).join());
      }
    });

    test('explicit length within bounds; outside bounds refused', () {
      expect(ykRandom('41', length: 16), hasLength(16));
      expect(() => ykRandom('41', length: 15),
          _throwsYk(YkException.lengthOutOfRange));
      expect(() => ykRandom('45', length: 13),
          _throwsYk(YkException.lengthOutOfRange));
      expect(() => ykRandom('nope'), _throwsYk(YkException.unknownField));
    });

    test('10k Random.secure draws per field: shape and uniformity', () {
      const draws = 10000;
      final counts = <String, Map<String, int>>{};
      final totals = <String, int>{};
      for (final e in ykFields.entries) {
        final alphabet = e.value.alphabet;
        final c = counts.putIfAbsent(alphabet, () => {});
        for (var i = 0; i < draws; i++) {
          final v = ykRandom(e.key);
          expect(v.length, e.value.max);
          for (var j = 0; j < v.length; j++) {
            c[v[j]] = (c[v[j]] ?? 0) + 1;
          }
          totals[alphabet] = (totals[alphabet] ?? 0) + v.length;
        }
        expect(ykCheckValue(e.key, ykRandom(e.key)), isEmpty);
      }
      expect(counts, hasLength(3));
      for (final e in counts.entries) {
        final alphabet = e.key;
        final n = alphabet.length;
        final total = totals[alphabet]!;
        final expected = total / n;
        final sigma = sqrt(total * (1 / n) * (1 - 1 / n));
        expect(e.value.keys.toSet(), alphabet.split('').toSet());
        for (final ch in alphabet.split('')) {
          expect((e.value[ch]! - expected).abs(), lessThan(6 * sigma),
              reason: 'char $ch of ${alphabet.length}-char alphabet');
        }
      }
    });
  });

  group('sha256_6', () {
    test('fixture values', () {
      for (final c in (edge['sha256_6'] as List).cast<Map<String, dynamic>>()) {
        expect(ykSha256Prefix6(c['value'] as String), c['sha256_6']);
      }
    });

    test('lone surrogate refused', () {
      expect(() => ykSha256Prefix6('a\uD800'), throwsArgumentError);
    });
  });
}
