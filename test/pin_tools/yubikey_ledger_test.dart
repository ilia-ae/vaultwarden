// Ledger Passwords → YubiKey PINs (yubikey-fleet docs/BITWARDEN.md). The
// fixture was generated with the real crypto_tools.pin24 from public test
// seeds only (BIP39 "abandon … about" and the Speculos seed).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/pin_tools/ledger_pin24.dart';
import 'package:vault_approver/pin_tools/yubikey_ledger.dart';
import 'package:vault_approver/pin_tools/yubikey_secrets.dart';

const _fixtures = 'test/pin_tools/fixtures';

Matcher _throwsYk(String code) =>
    throwsA(isA<YkException>().having((e) => e.code, 'code', code));

Matcher _throwsPin24(String code) =>
    throwsA(isA<Pin24Exception>().having((e) => e.code, 'code', code));

const _allPhases = {YkPhase.openpgp, YkPhase.fido2, YkPhase.oath, YkPhase.otp};

bool _printable(String s, int lowest) =>
    s.codeUnits.every((u) => u >= lowest && u <= 0x7E);

bool _csvUnsafe(String s) =>
    s.contains(',') ||
    s.contains('"') ||
    s.startsWith(' ') ||
    s.endsWith(' ') ||
    (s.isNotEmpty && '=+-@'.contains(s[0]));

Set<YkLedgerProblemKind> _kinds(List<YkLedgerProblem> p) =>
    {for (final x in p) x.kind};

void main() {
  final doc = jsonDecode(
    File('$_fixtures/yubikey_ledger.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final vectors = (doc['vectors'] as List).cast<Map<String, dynamic>>();

  // bip39ToSeed once per mnemonic (PBKDF2 is the slow part).
  final seeds = <String, Uint8List>{};
  Uint8List seedOf(Map<String, dynamic> v) => seeds.putIfAbsent(
      v['mnemonic'] as String, () => bip39ToSeed(v['mnemonic'] as String));

  Map<String, dynamic> vector(String seed, String serial, String mask) =>
      vectors.firstWhere((v) =>
          v['seed'] == seed && v['serial'] == serial && v['mask_name'] == mask);

  group('fixture replay (${vectors.length} vectors from pin24.py)', () {
    test('fixture shape', () {
      expect(vectors, hasLength(32));
      expect(doc['generator'], 'gen_yk_ledger_vectors.py');
      expect(
        {for (final v in vectors) v['set_mask']},
        {ykLedgerDefaultMask, kNumbers, 0x3F, kAllSets},
      );
      expect(ykLedgerDefaultMask, 0x07);
    });

    for (final v in vectors) {
      final serial = v['serial'] as String;
      final mask = v['set_mask'] as int;
      final pins = (v['pins'] as Map).cast<String, dynamic>();
      final puk = (v['puk'] as Map).cast<String, dynamic>();
      final admin = (v['admin'] as Map).cast<String, dynamic>();
      final label = '${v['seed']}/$serial/${v['mask_name']}';

      test('$label shared -pins entry', () {
        final r =
            ykFromLedger(bip39Seed: seedOf(v), serial: serial, setMask: mask);
        expect(r.serial, serial);
        expect(r.entries, {
          '00': 'yk-$serial-pins',
          '14': 'yk-$serial-puk',
          '23': 'yk-$serial-pins',
          '24': 'yk-$serial-pins',
          '34': 'yk-$serial-pins',
        });
        expect(pins['nickname'], 'yk-$serial-pins');
        expect(puk['nickname'], 'yk-$serial-puk');
        expect(r.outputs,
            {pins['nickname']: pins['full'], puk['nickname']: puk['full']});
        expect(r.entryNames, [pins['nickname'], puk['nickname']]);
        expect(r.values.keys, ['00', '14', '23', '24', '34']);
        expect(r.values['00'], pins['first4_last4']);
        expect(r.values['14'], puk['first4_last4']);
        expect(r.values['23'], pins['full']);
        expect(r.values['24'], pins['full']);
        expect(r.values['34'], pins['full']);

        // Condition 1 exactly where Python's generator flagged it.
        expect(
          _kinds(r.problems['00']!)
              .contains(YkLedgerProblemKind.notPrintableAscii),
          !(pins['printable_ascii_8'] as bool),
        );
        expect(
          _kinds(r.problems['14']!)
              .contains(YkLedgerProblemKind.notPrintableAscii),
          !(puk['printable_ascii_8'] as bool),
        );
        for (final f in ['23', '24', '34']) {
          final value = r.values[f]!;
          expect(value, hasLength(20));
          expect(
            _kinds(r.problems[f]!),
            {if (_csvUnsafe(value)) YkLedgerProblemKind.csvUnsafe},
            reason: f,
          );
        }
        for (final f in ['00', '14']) {
          final value = r.values[f]!;
          expect(
            _kinds(r.problems[f]!),
            {
              if (!_printable(value, 0x21))
                YkLedgerProblemKind.notPrintableAscii,
              if (_csvUnsafe(value)) YkLedgerProblemKind.csvUnsafe,
            },
            reason: f,
          );
        }
        expect(r.isValid, r.problems.values.every((p) => p.isEmpty));

        // Condition 2: the pick is 8 characters of every -pins secret. The
        // generator's literal-substring flag is a subset of that.
        expect((pins['full'] as String).contains(r.values['00']!),
            v['piv_pin_is_substring_of_pins_full']);
        expect(
          {for (final w in r.warnings['00']!) w.otherField},
          {'23', '24', '34'},
        );
        expect(
          r.warnings['00']!.map((w) => w.kind),
          everyElement(YkLedgerWarningKind.pivPinPartOfOtherSecret),
        );
        expect(r.warnings['24']!.single.kind,
            YkLedgerWarningKind.adminSharesPinsEntry);
        expect(r.warnings['14'], isEmpty);
        expect(r.warnings['23'], isEmpty);
        expect(r.hasWarnings, isTrue);
      });

      test('$label separate -admin entry', () {
        final r = ykFromLedger(
          bip39Seed: seedOf(v),
          serial: serial,
          setMask: mask,
          separateAdmin: true,
        );
        expect(admin['nickname'], 'yk-$serial-admin');
        expect(r.entries['24'], admin['nickname']);
        expect(r.outputs, {
          pins['nickname']: pins['full'],
          puk['nickname']: puk['full'],
          admin['nickname']: admin['full'],
        });
        expect(r.values['24'], admin['full']);
        expect(r.values['23'], pins['full']);
        expect(r.warnings['24'], isEmpty);
        final adminHoldsPin = ykLedgerPick8(admin['full'] as String) ==
                pins['first4_last4'] ||
            (admin['full'] as String).contains(pins['first4_last4'] as String);
        expect(
          {for (final w in r.warnings['00']!) w.otherField},
          {'23', '34', if (adminHoldsPin) '24'},
        );
      });
    }
  });

  group('ykFromLedger arguments', () {
    final v = vector('abandon12', '38715242', 'device_default');
    final pins = (v['pins'] as Map).cast<String, dynamic>();
    final puk = (v['puk'] as Map).cast<String, dynamic>();

    test('field subsets derive only the entries they need', () {
      final r = ykFromLedger(
          bip39Seed: seedOf(v), serial: '38715242', fields: const {'14'});
      expect(r.values, {'14': puk['first4_last4']});
      expect(r.entryNames, ['yk-38715242-puk']);
      expect(r.warnings, {'14': isEmpty});
      expect(r.problems, {'14': isEmpty});
      expect(r.isValid, isTrue);
      expect(r.hasWarnings, isFalse);

      final noPiv = ykFromLedger(
          bip39Seed: seedOf(v), serial: '38715242', fields: const {'23', '34'});
      expect(noPiv.values, {'23': pins['full'], '34': pins['full']});
      expect(noPiv.hasWarnings, isFalse);

      final adminOnly = ykFromLedger(
          bip39Seed: seedOf(v),
          serial: '38715242',
          separateAdmin: true,
          fields: const {'24'});
      expect(adminOnly.entryNames, ['yk-38715242-admin']);
    });

    test('the serial is stripped (Python whitespace) and otherwise verbatim',
        () {
      final r = ykFromLedger(bip39Seed: seedOf(v), serial: '\u0085 38715242\t');
      expect(r.serial, '38715242');
      expect(r.values['00'], pins['first4_last4']);
      expect(YkLedgerEntry.pins.nickname(' 00012345 '), 'yk-00012345-pins');
      expect(YkLedgerEntry.admin.nickname('7'), 'yk-7-admin');
      expect(ykLedgerEntryFor('24'), YkLedgerEntry.pins);
      expect(ykLedgerEntryFor('24', separateAdmin: true), YkLedgerEntry.admin);
      expect(() => ykLedgerEntryFor('25'), throwsArgumentError);
    });

    test('invalid inputs throw; unfit values never do', () {
      final seed = seedOf(v);
      expect(() => ykFromLedger(bip39Seed: seed, serial: ' \t'),
          _throwsYk(YkException.serialInvalid));
      expect(
          () => ykFromLedger(
              bip39Seed: seed, serial: 'a${String.fromCharCode(0xD800)}'),
          _throwsYk(YkException.serialInvalid));
      expect(() => ykFromLedger(bip39Seed: Uint8List(63), serial: '1'),
          _throwsPin24(Pin24Exception.seedLength));
      expect(() => ykFromLedger(bip39Seed: seed, serial: '1', setMask: 0),
          _throwsPin24(Pin24Exception.setMaskRange));
      expect(() => ykFromLedger(bip39Seed: seed, serial: '1', setMask: 256),
          _throwsPin24(Pin24Exception.setMaskRange));
      expect(
          () => ykFromLedger(
              bip39Seed: seed, serial: '1', fields: const {'00', '41'}),
          throwsArgumentError);
      final copy = Uint8List.fromList(seed);
      ykFromLedger(bip39Seed: seed, serial: '1', setMask: kAllSets);
      expect(seed, copy, reason: 'the caller-owned seed is not modified');
    });

    test('toString redacts every secret', () {
      final r = ykFromLedger(
          bip39Seed: seedOf(v), serial: '38715242', separateAdmin: true);
      final text = r.toString();
      for (final s in [...r.values.values, ...r.outputs.values]) {
        expect(text, isNot(contains(s)));
      }
      expect(text, contains('38715242'));
      for (final w in r.warnings.values.expand((w) => w)) {
        for (final s in r.values.values) {
          expect(w.message, isNot(contains(s)));
        }
      }
    });

    test('ykLedgerPick8', () {
      expect(ykLedgerPick8('abcdefghijklmnopqrst'), 'abcdqrst');
      expect(ykLedgerPick8('12345678'), '12345678');
      expect(() => ykLedgerPick8('1234567'), throwsArgumentError);
    });
  });

  group('ykValidateLedgerValue (card limits)', () {
    test('byte limits per field', () {
      Set<YkLedgerProblemKind> k(String f, String v) =>
          _kinds(ykValidateLedgerValue(f, v));
      const len = YkLedgerProblemKind.length;
      expect(ykHardwareLimits.keys, ykLedgerFields);
      for (final f in ['00', '14']) {
        expect(k(f, '12345'), {len});
        expect(k(f, '123456'), isEmpty);
        expect(k(f, 'Ab3dEf7h'), isEmpty);
        expect(k(f, '123456789'), {len});
      }
      expect(k('23', '12345'), {len});
      expect(k('23', '123456'), isEmpty);
      expect(k('23', 'a' * 127), isEmpty);
      expect(k('23', 'a' * 128), {len});
      expect(k('24', '1234567'), {len});
      expect(k('24', '12345678'), isEmpty);
      expect(k('34', '123'), {len});
      expect(k('34', '1234'), isEmpty);
      expect(k('34', 'a' * 63), isEmpty);
      expect(k('34', 'a' * 64), {len});
      // Bytes, not characters: 4 Cyrillic letters are 8 bytes.
      final p = ykValidateLedgerValue('00', 'ЖЖЖЖЖ');
      expect(p.first.kind, len);
      expect(p.first.byteLength, 10);
    });

    test('condition 1 and the unquoted CSV', () {
      Set<YkLedgerProblemKind> k(String f, String v) =>
          _kinds(ykValidateLedgerValue(f, v));
      const np = YkLedgerProblemKind.notPrintableAscii;
      const csv = YkLedgerProblemKind.csvUnsafe;
      const len = YkLedgerProblemKind.length;
      expect(k('00', 'ab cd123'), {np});
      expect(k('23', 'ab cd1234'), isEmpty, reason: 'inner space is fine');
      expect(k('00', 'abcdé12'), {np}, reason: '8 bytes, not ASCII');
      expect(k('00', 'abcdé123'), {len, np}, reason: '9 bytes');
      expect(k('00', 'abc\tefgh'), {np});
      expect(k('23', 'abc\u0000efgh'), {np});
      expect(k('23', 'abcd${String.fromCharCode(0xD800)}efgh'), {np});
      expect(k('00', r'!#$%&*./'), isEmpty);
      expect(k('23', 'abc,defgh'), {csv});
      expect(k('23', 'abc"defgh'), {csv});
      expect(k('23', ' abcdefgh'), {csv});
      expect(k('23', 'abcdefgh '), {csv});
      for (final c in ['=', '+', '-', '@']) {
        expect(k('34', '${c}abcdefg'), {csv}, reason: c);
      }
      expect(k('00', ' abc1234'), {np, csv});
      expect(() => ykValidateLedgerValue('41', 'x'), throwsArgumentError);
      final m = ykValidateLedgerValue('00', 'ab cd,12');
      expect(m.map((p) => p.message).join(' '), isNot(contains('ab cd')));
    });
  });

  group('--bitwarden export of Ledger values (separate validation path)', () {
    final master = ykNormalizeMasterKey(
        utf8.encode('SYNTHETIC-test-master-key-not-real-0123456789'));
    final v = vector('abandon12', '38715242', 'device_default');

    test('Ledger fields use card limits; the rest the fleet policy', () {
      final ledger = ykFromLedger(bip39Seed: seedOf(v), serial: '38715242');
      expect(ledger.isValid, isTrue);
      final k = ykResolveKeyWithLedger(
        ledger: ledger,
        phases: _allPhases,
        mode: YkMode.derived,
        master: master,
      );
      expect(k.ledgerFields, {'00', '14', '23', '24', '34'});
      expect(k.values.keys,
          ['00', '14', '23', '24', '25', '34', '41', '45', '46']);
      for (final f in ykLedgerFields) {
        expect(k.values[f], ledger.values[f]);
      }
      expect(k.values['25'],
          ykDerive(master: master, serial: '38715242', field: '25'));
      expect(k.values['41'],
          ykDerive(master: master, serial: '38715242', field: '41'));
      expect(k.values['45'], '000038715242');
      expect(k.values['46'], '000038715242');

      final csv = ykBitwardenCsv([k]);
      final lines = const LineSplitter().convert(csv);
      expect(lines.first, 'folder,name,field,value');
      expect(lines, hasLength(10));
      expect(lines[3],
          'yk-fleet,38715242,23 openpgp.user-pin,${v['pins']['full']}');
      expect(lines[1],
          'yk-fleet,38715242,00 piv.pin,${v['pins']['first4_last4']}');
      expect(csv.endsWith('\n'), isTrue);

      // The same values under the fleet policy: 20 characters > 16, letters
      // in the PIV PIN -> refused.
      final plain = YkKeySecrets(serial: k.serial, values: k.values);
      expect(
          () => ykBitwardenCsv([plain]), _throwsYk(YkException.valueInvalid));
      // And a non-Ledger field still gets the fleet policy.
      final badOath = YkKeySecrets(
        serial: k.serial,
        values: {...k.values, '41': 'short'},
        ledgerFields: k.ledgerFields,
      );
      expect(
          () => ykBitwardenCsv([badOath]), _throwsYk(YkException.valueInvalid));
    });

    test('random mode and phase subsets', () {
      final ledger = ykFromLedger(bip39Seed: seedOf(v), serial: '38715242');
      final draws = <int>[];
      final k = ykResolveKeyWithLedger(
        ledger: ledger,
        phases: const {YkPhase.fido2},
        mode: YkMode.random,
        otpFromSerial: false,
        manual: const {'00': '11111111', '34': 'manual-loses'},
        nextIntForTest: (max) {
          draws.add(max);
          return 0;
        },
      );
      expect(k.values.keys, ['00', '14', '34']);
      expect(k.ledgerFields, {'00', '14', '34'});
      expect(k.values['34'], ledger.values['34'], reason: 'Ledger over manual');
      expect(draws, isEmpty);
      expect(ykBitwardenCsv([k]).split('\n'), hasLength(5));

      final k2 = ykResolveKeyWithLedger(
        ledger: ykFromLedger(
            bip39Seed: seedOf(v), serial: '38715242', fields: const {'14'}),
        phases: const {YkPhase.oath},
        mode: YkMode.random,
        nextIntForTest: (max) => 1,
      );
      expect(k2.ledgerFields, {'14'});
      expect(k2.values['00'], '11111111', reason: 'random digits, index 1');
      expect(k2.values['41'], hasLength(32));
      expect(ykBitwardenCsv([k2]),
          contains('14 piv.puk,${v['puk']['first4_last4']}'));
    });

    test('unfit Ledger values are refused with VALUE_INVALID', () {
      // PIV PIN pick with a leading space (mask with separators).
      final spacey = vector('abandon12', '38715242', 'alnum_sep');
      expect(spacey['pins']['first4_last4'], startsWith(' '));
      final r1 = ykFromLedger(
          bip39Seed: seedOf(spacey), serial: '38715242', setMask: 0x3F);
      expect(r1.isValid, isFalse);
      expect(_kinds(r1.problems['00']!), {
        YkLedgerProblemKind.notPrintableAscii,
        YkLedgerProblemKind.csvUnsafe,
      });
      expect(
        () => ykBitwardenCsv([
          ykResolveKeyWithLedger(
              ledger: r1, phases: const {}, mode: YkMode.random),
        ]),
        _throwsYk(YkException.valueInvalid),
      );

      // Whole outputs with a comma (all character sets).
      final comma = vector('abandon12', '17684504', 'all');
      expect(comma['pins']['full'], contains(','));
      final r2 = ykFromLedger(
          bip39Seed: seedOf(comma), serial: '17684504', setMask: kAllSets);
      expect(_kinds(r2.problems['23']!), {YkLedgerProblemKind.csvUnsafe});
      expect(
        () => ykBitwardenCsv([
          ykResolveKeyWithLedger(
              ledger: r2, phases: const {YkPhase.openpgp}, mode: YkMode.random),
        ]),
        _throwsYk(YkException.valueInvalid),
      );
    });

    test('ledgerFields outside the card-limit table are a programming error',
        () {
      expect(
        () => ykBitwardenCsv([
          const YkKeySecrets(
            serial: '1',
            values: {
              '00': '12345678',
              '14': '12345678',
              '41': 'xxxxxxxxxxxxxxxx',
            },
            ledgerFields: {'41'},
          ),
        ]),
        throwsArgumentError,
      );
      expect(
        const YkKeySecrets(
            serial: '1', values: {'00': 'x'}, ledgerFields: {'00'}).toString(),
        'YkKeySecrets(1, fields: 00, ledger: 00)',
      );
    });
  });
}
