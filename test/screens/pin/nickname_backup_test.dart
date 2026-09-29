// PIN 24 nickname import (plan C1/D2, spec pin24-ui §2.9, critic #4): the
// backup parser, the file reader and the mask helpers, on synthetic files
// only (no real backup is ever read by the tests).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/pin_tools/ledger_pin24.dart';
import 'package:vault_approver/screens/pin/nickname_backup.dart';
import 'package:vault_approver/screens/pin/nickname_backup_picker.dart';
import 'package:vault_approver/screens/pin/pin24_engine.dart';

Uint8List _bytes(Object json) => Uint8List.fromList(utf8.encode(
      json is String ? json : jsonEncode(json),
    ));

NicknameBackup _parse(Object json) => parseNicknameBackup(_bytes(json));

Matcher _throwsBackup(NicknameBackupError error) => throwsA(
      isA<NicknameBackupException>().having((e) => e.error, 'error', error),
    );

void main() {
  group('parseNicknameBackup', () {
    test('ledger_pw.py format: nicknames and masks in file order', () {
      final b = _parse({
        'key_id': 'key-1',
        'description': 'synthetic test slot',
        'last_backup_at': '2026-05-20T15:30:00Z',
        'device': {'product': 'Ledger Stax', 'serial': '0001'},
        'parsed': [
          {
            'nickname': 'gmail',
            'charsets': ['UPPERCASE', 'LOWERCASE', 'NUMBERS'],
          },
          {
            'nickname': 'visa',
            'charsets': ['NUMBERS', 'MINUS', 'UNDERLINE', 'SPACE'],
          },
          {
            'nickname': 'all',
            'charsets': ['ALL_SETS'],
          },
        ],
      });
      expect(b.entries, const [
        NicknameBackupEntry(nickname: 'gmail', mask: 0x07),
        NicknameBackupEntry(nickname: 'visa', mask: kPinMask),
        NicknameBackupEntry(nickname: 'all', mask: kAllSets),
      ]);
      expect(b.skipped, 0);
    });

    test('missing, null or empty charsets mean ALL_SETS (0xFF)', () {
      final b = _parse({
        'parsed': [
          {'nickname': 'a'},
          {'nickname': 'b', 'charsets': null},
          {'nickname': 'c', 'charsets': <String>[]},
        ],
      });
      expect(b.entries.map((e) => e.mask), [kAllSets, kAllSets, kAllSets]);
    });

    test('MINUS-only is kept as the raw mask 0x08', () {
      final b = _parse({
        'parsed': [
          {
            'nickname': 'dash',
            'charsets': ['MINUS'],
          },
        ],
      });
      expect(b.entries.single.mask, kMinus);
      expect(pin24CharsetsForMask(kMinus), isNull);
    });

    test('nicknames are kept byte for byte (no trim, case or NFC)', () {
      final b = _parse({
        'parsed': [
          {'nickname': ' Visa '},
          {'nickname': 'cafe\u0301'},
          {'nickname': 'Карта-сбербанк-основная'}, // > 19 UTF-8 bytes: kept
        ],
      });
      expect(b.entries.map((e) => e.nickname),
          [' Visa ', 'cafe\u0301', 'Карта-сбербанк-основная']);
      expect(
          NicknameWarnings.of(b.entries.last.nickname).tooLong, isTrue); // soft
    });

    test('unusable entries are skipped and counted', () {
      final b = _parse({
        'parsed': [
          {'nickname': 'ok'},
          {'nickname': ''},
          {'nickname': 42},
          {'charsets': []},
          'not an object',
          {
            'nickname': 'unknown',
            'charsets': ['LOWERCASE', 'EMOJI'],
          },
          {
            'nickname': 'lower-case name',
            'charsets': ['numbers'],
          },
          {
            'nickname': 'dup-bit',
            'charsets': ['NUMBERS', 'NUMBERS'],
          },
          {
            'nickname': 'all-plus',
            'charsets': ['ALL_SETS', 'NUMBERS'],
          },
          {'nickname': 'not-a-list', 'charsets': 'NUMBERS'},
          {'nickname': 'ok'}, // duplicate nickname
          {'nickname': 'broken\ud800'}, // lone surrogate
        ],
      });
      expect(b.entries.map((e) => e.nickname), ['ok']);
      expect(b.skipped, 11);
    });

    test('a UTF-8 BOM is accepted', () {
      final bytes = Uint8List.fromList([
        0xEF, 0xBB, 0xBF, //
        ...utf8.encode('{"parsed":[{"nickname":"bom"}]}'),
      ]);
      expect(parseNicknameBackup(bytes).entries.single.nickname, 'bom');
    });

    test('empty list and no usable entry → empty', () {
      expect(() => _parse({'parsed': []}),
          _throwsBackup(NicknameBackupError.empty));
      expect(
          () => _parse({
                'parsed': [
                  {'nickname': ''},
                ],
              }),
          _throwsBackup(NicknameBackupError.empty));
    });

    test('malformed input → unreadable, and the error never quotes it', () {
      for (final bad in <Object>[
        '{"parsed": [ {"nickname": "SECRET-LOOKING-NAME" ',
        'not json at all',
        '[1, 2, 3]',
        {'parsed': 'nope'},
        {'nicknames': []},
        '',
      ]) {
        expect(() => _parse(bad), _throwsBackup(NicknameBackupError.unreadable),
            reason: '$bad');
      }
      // Invalid UTF-8.
      expect(() => parseNicknameBackup(Uint8List.fromList([0x7B, 0xC3, 0x28])),
          _throwsBackup(NicknameBackupError.unreadable));
      try {
        _parse('{"parsed": [ {"nickname": "SECRET-LOOKING-NAME" ');
      } on NicknameBackupException catch (e) {
        expect(e.toString(), isNot(contains('SECRET')));
        expect(e.toString(), 'NicknameBackupException(unreadable)');
      }
    });

    test('over 1 MB → tooLarge before any parsing', () {
      final big = Uint8List(kNicknameBackupMaxBytes + 1);
      expect(() => parseNicknameBackup(big),
          _throwsBackup(NicknameBackupError.tooLarge));
    });

    test('at most kNicknameBackupMaxEntries entries are kept', () {
      final b = _parse({
        'parsed': [
          for (var i = 0; i < kNicknameBackupMaxEntries + 5; i++)
            {'nickname': 'n$i'},
        ],
      });
      expect(b.entries, hasLength(kNicknameBackupMaxEntries));
      expect(b.skipped, 5);
    });

    test('toString never shows nicknames', () {
      final b = _parse({
        'parsed': [
          {'nickname': 'my-bank'},
        ],
      });
      expect(b.toString(), isNot(contains('my-bank')));
      expect(b.entries.single.toString(), isNot(contains('my-bank')));
    });
  });

  group('ledgerCharsetsToMask (ledger_pw.charsets_to_mask)', () {
    test('every single name and ALL_SETS', () {
      for (final (name, bit) in kLedgerCharsetNames) {
        expect(ledgerCharsetsToMask([name]), bit, reason: name);
      }
      expect(ledgerCharsetsToMask(['ALL_SETS']), 0xFF);
      expect(
          ledgerCharsetsToMask([
            for (final (name, _) in kLedgerCharsetNames) name,
          ]),
          0xFF);
    });
  });

  group('pin24CharsetsForMask', () {
    test('toggle groups round-trip, partial groups do not', () {
      // Every one of the 32 toggle combinations.
      for (var i = 0; i < 32; i++) {
        final set = {
          for (final (j, c) in Pin24Charset.values.indexed)
            if (i & (1 << j) != 0) c,
        };
        expect(pin24CharsetsForMask(pin24MaskOf(set)), set, reason: '$i');
      }
      for (final partial in [kMinus, kUnderline, kSpace, kSpecial, kBrackets]) {
        expect(pin24CharsetsForMask(partial), isNull);
        expect(pin24CharsetsForMask(kNumbers | partial), isNull);
      }
      expect(pin24CharsetsForMask(kAllSets), Pin24Charset.values.toSet());
      expect(pin24CharsetsForMask(-1), isNull);
      expect(pin24CharsetsForMask(0x100), isNull);
    });

    test('raw labels show the exact sets', () {
      expect(ledgerCharsetsLabel(kMinus), 'MINUS (-)');
      expect(
          ledgerCharsetsLabel(kNumbers | kSpace), 'NUMBERS (0-9) + SPACE (␣)');
      expect(ledgerCharsetsLabel(kBrackets), 'BRACKETS ([]{}()<>)');
    });
  });

  group('synthetic backup files', () {
    late Directory dir;

    setUpAll(() {
      dir = Directory.systemTemp.createTempSync('va_nickname_backup_');
    });
    tearDownAll(() => dir.deleteSync(recursive: true));

    Future<NicknameBackup> read(String name, List<int> content) async {
      final file = File('${dir.path}/$name')..writeAsBytesSync(content);
      return parseNicknameBackup(
          await readNicknameBackupFile(XFile(file.path)));
    }

    test('valid', () async {
      final b = await read(
          'valid.json',
          utf8.encode(const JsonEncoder.withIndent('  ').convert({
            'key_id': 'key-9',
            'parsed': [
              {
                'nickname': 'gmail',
                'charsets': ['UPPERCASE', 'LOWERCASE', 'NUMBERS'],
              },
              {
                'nickname': 'dash',
                'charsets': ['MINUS'],
              },
              {'nickname': 'any'},
            ],
          })));
      expect(b.entries.map((e) => (e.nickname, e.mask)),
          [('gmail', 0x07), ('dash', 0x08), ('any', 0xFF)]);
    });

    test('empty', () async {
      await expectLater(read('empty.json', utf8.encode('{"parsed": []}')),
          _throwsBackup(NicknameBackupError.empty));
      await expectLater(read('zero.json', const []),
          _throwsBackup(NicknameBackupError.unreadable));
    });

    test('malformed', () async {
      await expectLater(
          read('malformed.json', utf8.encode('{"parsed": [{"nickname": ')),
          _throwsBackup(NicknameBackupError.unreadable));
    });

    test('missing charsets', () async {
      final b = await read(
          'missing.json', utf8.encode('{"parsed":[{"nickname":"visa"}]}'));
      expect(b.entries.single.mask, kAllSets);
    });

    test('MINUS-only mask', () async {
      final b = await read('minus.json',
          utf8.encode('{"parsed":[{"nickname":"x","charsets":["MINUS"]}]}'));
      expect(b.entries.single.mask, kMinus);
    });

    test('huge file is refused before it is read', () async {
      final huge = List<int>.filled(kNicknameBackupMaxBytes + 1, 0x20);
      await expectLater(
          read('huge.json', huge), _throwsBackup(NicknameBackupError.tooLarge));
      // Exactly the limit is still read (and then judged on its content).
      final atLimit = List<int>.filled(kNicknameBackupMaxBytes, 0x20);
      await expectLater(read('limit.json', atLimit),
          _throwsBackup(NicknameBackupError.unreadable));
    });
  });

  test('only the picker file of the PIN code reads files', () {
    final readers = [
      for (final f in Directory('lib/screens/pin')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')))
        if (f.readAsStringSync().contains('package:file_selector/'))
          f.path.split('/').last,
    ];
    expect(readers, ['nickname_backup_picker.dart']);
  });
}
