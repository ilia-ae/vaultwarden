// Replays the Python-generated vectors for crypto_tools/pin24.py against the
// Dart port. Fixtures: test/pin_tools/fixtures/pin24_*.json (public seeds
// only: BIP39 "abandon … about"-family test mnemonics and the Speculos seed).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;
import 'package:vault_approver/pin_tools/bip39.dart';
import 'package:vault_approver/pin_tools/ledger_pin24.dart';
import 'package:vault_approver/pin_tools/python_text.dart';

const _fixtureDir = 'test/pin_tools/fixtures';

Map<String, dynamic> _load(String name) =>
    jsonDecode(File('$_fixtureDir/$name').readAsStringSync())
        as Map<String, dynamic>;

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _unhex(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

Uint8List _sha256(List<int> data) =>
    SHA256Digest().process(Uint8List.fromList(data));

int _parseHexInt(String s) => int.parse(s.substring(2), radix: 16);

String _str(Object? cps) => String.fromCharCodes((cps! as List).cast<int>());

Matcher _pin24Error(String code) =>
    isA<Pin24Exception>().having((e) => e.code, 'code', code);

/// Records every round-key schedule the engine hands to AESEngine.
class _SpyAes extends WipeableAesEngine {
  final schedules = <List<List<int>>>[];

  @override
  List<List<int>> generateWorkingKey(
    bool forEncryption,
    KeyParameter params,
  ) {
    final schedule = super.generateWorkingKey(forEncryption, params);
    schedules.add(schedule);
    return schedule;
  }
}

bool _allZero(List<List<int>> schedule) =>
    schedule.every((round) => round.every((w) => w == 0));

const _abandon12 = 'abandon abandon abandon abandon abandon abandon abandon '
    'abandon abandon abandon abandon about';
const _speculos = 'glory promote mansion idle axis finger extra february '
    'uncover one trip resource lawn turtle enact monster seven myth punch '
    'hobby comfort wild raise skin';

/// Python keyword → Dart named parameter, for replaying `inputs` maps with
/// exactly the arguments Python received (omitted ones take the defaults).
Map<Symbol, dynamic> _namedArgs(Map<String, dynamic> inputs) {
  final args = <Symbol, dynamic>{};
  inputs.forEach((k, value) {
    switch (k) {
      case 'seed_phrase':
        args[#seedPhrase] = value as String;
      case 'bip39_seed_hex':
        args[#bip39Seed] = _unhex(value as String);
      case 'nickname':
        args[#nickname] = value as String;
      case 'set_mask':
        args[#setMask] = value as int;
      case 'min_from_set':
        args[#minFromSet] = (value as List).cast<int>();
      case 'size':
        args[#size] = value as int;
      case 'length':
        args[#length] = value as int;
      case 'bip39_passphrase':
        args[#bip39Passphrase] = value as String;
      case 'nickname_utf16_code_units':
        break; // cross-checked separately
      default:
        fail('unknown input key $k');
    }
  });
  return args;
}

Object? _invoke(String function, Map<String, dynamic> inputs) {
  switch (function) {
    case 'derive_password':
      return Function.apply(derivePassword, const [], _namedArgs(inputs));
    case 'derive_pin':
      return Function.apply(derivePin, const [], _namedArgs(inputs));
    case 'bip39_to_seed':
      return bip39ToSeed(
        inputs['phrase'] as String,
        passphrase: (inputs['passphrase'] as String?) ?? '',
      );
  }
  fail('unknown function $function');
}

void _expectPin24Error(
  String function,
  Map<String, dynamic> inputs,
  String code,
  String message,
) {
  try {
    _invoke(function, inputs);
  } on Pin24Exception catch (e) {
    expect(e.code, code);
    expect(e.message, message);
    return;
  }
  fail('expected Pin24Exception($code)');
}

void main() {
  final vectorsDoc = _load('pin24_vectors.json');
  final chain = _load('pin24_chain.json');
  final errorsDoc = _load('pin24_errors.json');
  final primitives = _load('pin24_primitives.json');
  final extra = _load('pin24_extra.json');
  final uiDerivation = _load('pin24_ui_derivation.json');

  final vectors = (vectorsDoc['vectors'] as List).cast<Map<String, dynamic>>();
  final seedTable = (chain['seeds'] as Map).cast<String, dynamic>();
  final leafTable = (chain['leaves'] as Map).cast<String, dynamic>();

  // bip39ToSeed results keyed by (mnemonic, passphrase): the intermediate
  // checks reuse them so PBKDF2 runs once per distinct input.
  final seedCache = <String, Uint8List>{};
  Uint8List cachedSeed(String mnemonic, String passphrase) =>
      seedCache.putIfAbsent(
        '$mnemonic\u0000$passphrase',
        () => bip39ToSeed(mnemonic, passphrase: passphrase),
      );

  group('official LedgerHQ/app-passwords vectors (Speculos seed)', () {
    // upstream tests/functional/tests_vectors.py, as pinned in
    // personal-crypto-tools tests/test_pin24.py
    const official = <(int, String, String)>[
      (0x01, 'gmail', 'HMYDQUIOVKPCKJIHQJEN'),
      (0x03, 'gmail', 'KqIJcPjhENivHvOdmuKQ'),
      (0x07, 'gmail', 'xNX8IQO4vP0ucO41J6JW'),
      (0x0F, 'gmail', 'w14JrbA9HNvWU1ON5MGP'),
      (0x1F, 'gmail', 'vy4Joa86FKvVS1ON4KEP'),
      (0x3F, 'gmail', 'kD83CP1UZO vQvJIuNx4'),
      (0x7F, 'gmail', '?u8htP1|DO v7vJzYNb4'),
      (0xFF, 'gmail', '*m8ZlP1|}O vzvJrQNT4'),
      (0xFF, 'aseedoflengthequal20', '29!uO;UPx UT8Hkmi- 5'),
      (0xFF, 'aSeedOfLengthEqual20', r' $4,P.usI*C\k1fv2;M;'),
    ];
    for (final (mask, nickname, expected) in official) {
      final label = '0x${mask.toRadixString(16).padLeft(2, '0')}/$nickname';
      test(label, () {
        expect(
          derivePassword(
            seedPhrase: _speculos,
            nickname: nickname,
            setMask: mask,
          ),
          expected,
        );
      });
    }

    test('fixture official-01..10 are exactly these ten', () {
      final fromFixture = [
        for (final v in vectors)
          if ((v['tags'] as List).contains('official'))
            (
              (v['options'] as Map)['set_mask'] as int,
              v['nickname'] as String,
              v['expected_output'] as String,
            ),
      ];
      expect(fromFixture, official);
      expect(
        vectors
            .where((v) => (v['tags'] as List).contains('official'))
            .every((v) => v['mnemonic'] == _speculos),
        isTrue,
      );
    });
  });

  group('pin24 vectors: all intermediates', () {
    test('fixture shape', () {
      expect(vectors, hasLength(227));
      final usedSeeds = {for (final v in vectors) v['seed']};
      final usedLeaves = {
        for (final v in vectors) '${v['seed']}:${v['nickname_utf8_hex']}',
      };
      expect(usedSeeds, seedTable.keys.toSet());
      expect(usedLeaves, leafTable.keys.toSet());
    });

    for (final v in vectors) {
      test(v['id'] as String, () {
        final function = v['function'] as String;
        final options = (v['options'] as Map).cast<String, dynamic>();
        final explicit = (options['explicit_args'] as List).cast<String>();
        final mnemonic = v['mnemonic'] as String?;
        final passphrase = v['passphrase'] as String;
        final nickname = v['nickname'] as String;
        final seedInputHex = v['bip39_seed_input_hex'] as String?;

        // ── 1. End to end through the public API, with exactly the
        //       arguments Python received (defaults otherwise).
        final inputs = <String, dynamic>{
          if (mnemonic != null) 'seed_phrase': mnemonic,
          if (seedInputHex != null) 'bip39_seed_hex': seedInputHex,
          'nickname': nickname,
          for (final arg in explicit)
            arg: arg == 'bip39_passphrase' ? passphrase : options[arg],
        };
        expect(_invoke(function, inputs), v['expected_output']);
        if (function == 'derive_pin') {
          final d =
              Function.apply(derivePinDetailed, const [], _namedArgs(inputs))
                  as PinDerivation;
          final full = v['expected_password'] as String;
          final digits = full.codeUnits.where((c) => c >= 0x30 && c <= 0x39);
          final length = options['length'] as int;
          expect(d.pin, v['expected_output']);
          expect(d.fullPassword, full);
          expect(d.digitsInOutput, digits.length);
          expect(
            d.paddedZeros,
            digits.length >= length ? 0 : length - digits.length,
          );
        }
        // Omitted arguments must equal Python's defaults.
        if (!explicit.contains('set_mask')) {
          expect(options['set_mask'], kPinMask);
        }
        if (!explicit.contains('min_from_set')) {
          expect(options['min_from_set'], kDefaultMinSet);
        }
        if (!explicit.contains('size')) {
          expect(options['size'], kPasswordMaxSize);
        }

        // ── 2. BIP39 seed.
        final seedEntry = seedTable[v['seed']] as Map<String, dynamic>;
        final Uint8List seed;
        if (mnemonic != null) {
          expect(
            normalizeSeedPhrase(mnemonic),
            v['expected_normalized_mnemonic'] ?? mnemonic,
          );
          seed = cachedSeed(mnemonic, passphrase);
        } else {
          seed = _unhex(seedInputHex!);
        }
        expect(_hex(seed), seedEntry['seed_hex']);
        if (passphrase.isNotEmpty) {
          expect(
            _hex(utf8.encode(pythonNfkd(passphrase))),
            v['passphrase_nfkd_utf8_hex'],
          );
        }

        // ── 3. Nickname → path.
        expect(_hex(utf8.encode(nickname)), v['nickname_utf8_hex']);
        final leaf = leafTable['${v['seed']}:${v['nickname_utf8_hex']}']
            as Map<String, dynamic>;
        expect(
            _hex(_sha256(utf8.encode(nickname))), leaf['nickname_sha256_hex']);
        final path = nicknamePath(nickname);
        expect(
          path,
          [for (final p in leaf['path'] as List) _parseHexInt(p as String)],
        );

        // ── 4. BIP32 master → leaf → entropy.
        var node = bip32Master(seed);
        expect(_hex(node.key), seedEntry['master_key_hex']);
        expect(_hex(node.chain), seedEntry['master_chain_hex']);
        for (final index in path) {
          node = bip32HardenedChild(node.key, node.chain, index);
        }
        expect(_hex(node.key), leaf['leaf_key_hex']);
        expect(_hex(node.chain), leaf['leaf_chain_hex']);
        final entropy = _sha256([...node.key, ...node.chain]);
        expect(_hex(entropy), leaf['entropy_hex']);

        // ── 5. CTR_DRBG instantiate.
        expect(_hex(blockCipherDf(entropy)), leaf['df_output_hex']);
        final drbg = CtrDrbg.instantiate(entropy);
        expect(_hex(drbg.key), leaf['drbg_key_hex']);
        expect(_hex(drbg.v), leaf['drbg_v_hex']);

        // ── 6. Sampling, then shuffle, with draw counts.
        final isPin = function == 'derive_pin';
        final buf = sampleUnshuffled(
          drbg,
          setMask: isPin ? kPinMask : options['set_mask'] as int,
          minFromSet: isPin
              ? kDefaultMinSet
              : (options['min_from_set'] as List).cast<int>(),
          size: isPin ? kPasswordMaxSize : options['size'] as int,
        );
        expect(String.fromCharCodes(buf), v['expected_pre_shuffle']);
        expect(drbg.generateCalls, v['expected_draws_before_shuffle']);
        shuffleInPlace(drbg, buf);
        expect(String.fromCharCodes(buf), v['expected_password']);
        expect(drbg.generateCalls, v['expected_rng_draws']);

        // ── 7. The raw candidate byte stream (rejected bytes included).
        final replay = CtrDrbg.instantiate(entropy);
        final draws = v['expected_rng_draws'] as int;
        final stream = [for (var i = 0; i < draws; i++) replay.generate(1)[0]];
        expect(_hex(stream), v['expected_rng_bytes_hex']);
      });
    }
  });

  group('pin24 error vectors', () {
    final cases = (errorsDoc['cases'] as List).cast<Map<String, dynamic>>();

    test('fixture has all 52 cases', () => expect(cases, hasLength(52)));

    for (final c in cases) {
      test(c['id'] as String, () {
        final inputs = (c['inputs'] as Map).cast<String, dynamic>();
        final units = inputs['nickname_utf16_code_units'] as List?;
        if (units != null) {
          expect((inputs['nickname'] as String).codeUnits, units);
        }
        _expectPin24Error(
          c['function'] as String,
          inputs,
          c['error_code'] as String,
          c['error_message'] as String,
        );
      });
    }
  });

  group('extra cases computed with the real Python code', () {
    for (final c in (extra['errors'] as List).cast<Map<String, dynamic>>()) {
      test('error ${c['id']}', () {
        final inputs = (c['inputs'] as Map).cast<String, dynamic>();
        ((c['utf16'] as Map?) ?? const {}).forEach((k, units) {
          expect((inputs[k] as String).codeUnits, units, reason: '$k units');
        });
        _expectPin24Error(
          c['function'] as String,
          inputs,
          c['error_code'] as String,
          c['error_message'] as String,
        );
      });
    }
    for (final c in (extra['vectors'] as List).cast<Map<String, dynamic>>()) {
      test('vector ${c['id']}', () {
        final inputs = (c['inputs'] as Map).cast<String, dynamic>();
        ((c['utf16'] as Map?) ?? const {}).forEach((k, units) {
          expect((inputs[k] as String).codeUnits, units, reason: '$k units');
        });
        expect(
          _invoke(c['function'] as String, inputs),
          c['expected_output'],
        );
      });
    }

    test('lower()+NFKD parity with Python over every code point', () {
      // Which single code points fold (Python str.lower, then NFKD) into
      // ASCII a-z decides BIP39 acceptance. Checked in both directions.
      final expected = (extra['nfkd_lower_ascii_letters'] as Map)
          .map((k, v) => MapEntry(int.parse(k as String), v as String));
      final lowerAscii = (extra['lower_to_ascii_non_ascii'] as Map)
          .map((k, v) => MapEntry(int.parse(k as String), v as String));
      final letters = RegExp(r'^[a-z]+$');
      final hasAsciiLetter = RegExp('[a-z]');
      final foldMismatches = <String>[];
      final lowerMismatches = <String>[];
      for (var cp = 0; cp < 0x110000; cp++) {
        if (cp >= 0xD800 && cp <= 0xDFFF) continue;
        final c = String.fromCharCode(cp);
        final lower = pythonLower(c);
        final folded = pythonNfkd(lower);
        final want = expected[cp];
        if (letters.hasMatch(folded) ? folded != want : want != null) {
          foldMismatches.add('U+${cp.toRadixString(16)}');
        }
        final isAsciiLetter =
            (cp >= 0x41 && cp <= 0x5A) || (cp >= 0x61 && cp <= 0x7A);
        // Non-ASCII code points whose lower() contains a-z (U+0130, U+212A)
        // must match Python exactly; no other one may produce a-z.
        final producesAscii = !isAsciiLetter && hasAsciiLetter.hasMatch(lower);
        if (producesAscii
            ? lower != lowerAscii[cp]
            : lowerAscii.containsKey(cp)) {
          lowerMismatches.add('U+${cp.toRadixString(16)}');
        }
      }
      expect(foldMismatches, isEmpty);
      expect(lowerMismatches, isEmpty);
      expect(expected, hasLength(632));
    });
  });

  group('primitives', () {
    test('constants match the Python module', () {
      final k = (primitives['constants'] as Map).cast<String, dynamic>();
      expect(kUppercase, k['UPPERCASE']);
      expect(kLowercase, k['LOWERCASE']);
      expect(kNumbers, k['NUMBERS']);
      expect(kMinus, k['MINUS']);
      expect(kUnderline, k['UNDERLINE']);
      expect(kSpace, k['SPACE']);
      expect(kSpecial, k['SPECIAL']);
      expect(kBrackets, k['BRACKETS']);
      expect(kAllSets, k['ALL_SETS']);
      expect(kBars, k['BARS']);
      expect(kExtSymbols, k['EXT_SYMBOLS']);
      expect(kCharsets, hasLength(k['NUM_SETS'] as int));
      expect(kDefaultMinSet, k['DEFAULT_MIN_SET']);
      expect(kDerivePasswordPath, k['DERIVE_PASSWORD_PATH']);
      expect(kPasswordMaxSize, k['PASSWORD_MAX_SIZE']);
      expect(kPinMask, k['default_set_mask']);
      expect(kPinMask, kNumbers | kBars);
      expect(kBars, kMinus | kUnderline | kSpace);
      expect(kExtSymbols, kSpecial | kBrackets);
      expect(kPinMaxLength, 12);
      expect(
        k['SECP256K1_N_hex'],
        'fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141',
      );
    });

    test('charsets are byte-identical and in bit order', () {
      final sets = (primitives['sets'] as List).cast<Map<String, dynamic>>();
      for (final s in sets) {
        final i = s['index'] as int;
        expect(1 << i, s['bit']);
        expect(kCharsets[i], s['chars']);
        expect(_hex(kCharsets[i].codeUnits), s['hex']);
        expect(kCharsets[i].length, s['len']);
      }
      expect(kCharsets.join().length, 95);
    });

    test('Python whitespace set', () {
      final cps = [
        for (final s in primitives['python_whitespace_codepoints'] as List)
          int.parse((s as String).substring(2), radix: 16),
      ];
      expect(pythonWhitespace, cps.toSet());
    });

    test('AES-256 NIST SP 800-38A F.1.5', () {
      final a = (primitives['aes256_ecb_nist'] as Map).cast<String, dynamic>();
      final aes = AESEngine()
        ..init(true, KeyParameter(_unhex(a['key_hex'] as String)));
      final out = Uint8List(16);
      aes.processBlock(_unhex(a['plaintext_hex'] as String), 0, out, 0);
      expect(_hex(out), a['ciphertext_hex']);
    });

    test('block_cipher_df', () {
      final dfs =
          (primitives['block_cipher_df'] as List).cast<Map<String, dynamic>>();
      expect(dfs, hasLength(7));
      for (final d in dfs) {
        expect(
          _hex(blockCipherDf(_unhex(d['input_hex'] as String))),
          d['output_hex'],
        );
      }
      expect(() => blockCipherDf(Uint8List(385)), throwsArgumentError);
    });

    test('CTR_DRBG traces (state after every call)', () {
      final traces =
          (primitives['ctr_drbg'] as List).cast<Map<String, dynamic>>();
      expect(traces, hasLength(3));
      for (final t in traces) {
        final entropy = _unhex(t['entropy_hex'] as String);
        expect(_hex(blockCipherDf(entropy)), t['df_output_hex']);
        final drbg = CtrDrbg.instantiate(entropy);
        final after = (t['after_instantiate'] as Map).cast<String, dynamic>();
        expect(_hex(drbg.key), after['key_hex']);
        expect(_hex(drbg.v), after['v_hex']);
        for (final call in (t['calls'] as List).cast<Map<String, dynamic>>()) {
          expect(_hex(drbg.generate(call['n'] as int)), call['output_hex']);
          expect(_hex(drbg.key), call['key_after_hex']);
          expect(_hex(drbg.v), call['v_after_hex']);
        }
        drbg.wipe();
        expect(drbg.key, everyElement(0));
        expect(drbg.v, everyElement(0));
      }
      expect(() => CtrDrbg.instantiate(Uint8List(31)), throwsArgumentError);
    });

    test('rng_u8_modulo traces, candidate == limit accepted, rejection', () {
      final traces =
          (primitives['rng_u8_modulo'] as List).cast<Map<String, dynamic>>();
      expect(traces, hasLength(3));
      for (final t in traces) {
        final entropy = _unhex(t['entropy_hex'] as String);
        final drbg = CtrDrbg.instantiate(entropy);
        final replay = CtrDrbg.instantiate(entropy);
        final steps = t.containsKey('steps')
            ? (t['steps'] as List).cast<Map<String, dynamic>>()
            : [
                {
                  'modulo': t['modulo'],
                  'rng_limit': t['rng_limit'],
                  'candidates': [t['first_candidate']],
                  'result': t['result'],
                },
              ];
        for (final s in steps) {
          final m = s['modulo'] as int;
          final candidates = (s['candidates'] as List).cast<int>();
          expect(256 - 256 % m, s['rng_limit']);
          final before = drbg.generateCalls;
          expect(drbg.rngU8Modulo(m), s['result']);
          expect(drbg.generateCalls - before, candidates.length);
          expect(
            [for (final _ in candidates) replay.generate(1)[0]],
            candidates,
          );
        }
      }
      final boundary = traces[1];
      expect(boundary['first_candidate'], boundary['rng_limit']);
      final rejection =
          ((traces[2]['steps'] as List).first as Map)['candidates'] as List;
      expect(rejection, hasLength(2));
    });

    test('rng_u8_modulo argument checks', () {
      final drbg = CtrDrbg.instantiate(Uint8List(32));
      Pin24Exception err(int m) {
        try {
          drbg.rngU8Modulo(m);
        } on Pin24Exception catch (e) {
          return e;
        }
        fail('no exception for $m');
      }

      expect(err(0).code, Pin24Exception.moduloRange);
      expect(err(0).message, 'modulo must be > 0');
      expect(err(257).message, 'rng_u8_modulo only supports modulo <= 256');
      expect(drbg.generateCalls, 0);
      expect(drbg.generate(0), isEmpty);
      expect(drbg.generateCalls, 0);
    });

    test('BIP32 spec vector 1 and the abandon seed', () {
      final b = (primitives['bip32'] as Map).cast<String, dynamic>();
      void expectNode(Bip32Node n, Object? want) {
        final w = (want as Map).cast<String, dynamic>();
        expect(_hex(n.key), w['key_hex']);
        expect(_hex(n.chain), w['chain_hex']);
      }

      final master = bip32Master(_unhex(b['spec_vector_1_seed_hex'] as String));
      expectNode(master, b['master']);
      var node = bip32HardenedChild(master.key, master.chain, 0x80000000);
      expectNode(node, b['m_0h']);
      for (var i = 0; i < 2; i++) {
        node = bip32HardenedChild(node.key, node.chain, 0x80000000);
      }
      expectNode(node, b['m_0h_0h_0h']);

      final aboutMaster = bip32Master(cachedSeed(_abandon12, ''));
      expectNode(aboutMaster, b['abandon_about_master']);
      final pwd = b['abandon_about_m_5265220h'] as Map;
      expect(_parseHexInt(pwd['index_hex'] as String), kDerivePasswordPath);
      expectNode(
        bip32HardenedChild(
            aboutMaster.key, aboutMaster.chain, kDerivePasswordPath),
        pwd,
      );
      aboutMaster.wipe();
      expect(aboutMaster.key, everyElement(0));
      expect(aboutMaster.chain, everyElement(0));
    });

    test('BIP32 argument checks use the Python messages', () {
      Pin24Exception err(void Function() f) {
        try {
          f();
        } on Pin24Exception catch (e) {
          return e;
        }
        fail('no exception');
      }

      final k = Uint8List(32)..[31] = 1;
      final c = Uint8List(32);
      var e = err(() => bip32HardenedChild(k, c, 0x7fffffff));
      expect(e.code, Pin24Exception.bip32Invalid);
      expect(e.message,
          'Hardened index must be in [0x80000000, 0xFFFFFFFF]; got 0x7fffffff');
      e = err(() => bip32HardenedChild(k, c, 0x100000000));
      expect(e.message, endsWith('got 0x100000000'));
      e = err(() => bip32HardenedChild(k, c, -5));
      expect(e.message, endsWith('got -0x5'));
      e = err(() => bip32Master(Uint8List(15)));
      expect(e.message,
          'BIP32 master seed must be 16..64 bytes (typical: 64 for BIP39)');
      e = err(() => bip32Master(Uint8List(65)));
      expect(e.code, Pin24Exception.bip32Invalid);
      expect(bip32Master(Uint8List(16)).key, hasLength(32));
    });

    test('nickname -> path', () {
      for (final n in (primitives['nickname_to_path'] as List)
          .cast<Map<String, dynamic>>()) {
        final nick = n['nickname'] as String;
        expect(_hex(utf8.encode(nick)), n['utf8_hex']);
        expect(_hex(_sha256(utf8.encode(nick))), n['sha256_hex']);
        expect(
          nicknamePath(nick),
          [for (final p in n['path'] as List) _parseHexInt(p as String)],
        );
      }
    });

    test('shuffle example', () {
      final s = (primitives['shuffle_example'] as Map).cast<String, dynamic>();
      final entropy = _unhex(s['entropy_hex'] as String);
      final drbg = CtrDrbg.instantiate(entropy);
      final buf = Uint8List.fromList((s['input'] as String).codeUnits);
      shuffleInPlace(drbg, buf);
      expect(String.fromCharCodes(buf), s['output']);
      final candidates = (s['candidates'] as List).cast<int>();
      expect(drbg.generateCalls, candidates.length);
      final replay = CtrDrbg.instantiate(entropy);
      expect([for (final _ in candidates) replay.generate(1)[0]], candidates);
    });
  });

  group('BIP39 seed and normalisation', () {
    test('python tests/test_pin24.py cases', () {
      expect(normalizeSeedPhrase('  abandon   about '), 'abandon about');
      expect(normalizeSeedPhrase('Abandon ABOUT'), 'abandon about');
      expect(
        _hex(bip39ToSeed(_abandon12)),
        '5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc1'
        '9a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4',
      );
      expect(
        () => bip39ToSeed('${'abandon ' * 11}abandon'),
        throwsA(isA<Pin24Exception>()
            .having((e) => e.code, 'code', Pin24Exception.bip39Invalid)),
      );
    });

    test('normalisation follows Python, not Dart, whitespace', () {
      expect(normalizeSeedPhrase('a\u001cb\u0085c\u3000d'), 'a b c d');
      expect(normalizeSeedPhrase('\ufeffa\u200bb'), '\ufeffa\u200bb');
      expect(normalizeSeedPhrase('\u0130'), 'i\u0307');
      expect(normalizeSeedPhrase(''), '');
    });

    test('a raw seed is never modified and the passphrase is ignored', () {
      final seed = _unhex(
        '5eb00bbddcf069084889a8ab9155568165f5c453ccb85e70811aaed6f6da5fc1'
        '9a5ac40b389cd370d086206dec8aa6c43daea6690f20ad3d8d48b2d2ce9e38e4',
      );
      final copy = Uint8List.fromList(seed);
      final a = derivePassword(bip39Seed: seed, nickname: 'visa');
      final b = derivePassword(
          bip39Seed: seed, nickname: 'visa', bip39Passphrase: 'TREZOR');
      expect(a, b);
      expect(a, derivePassword(seedPhrase: _abandon12, nickname: 'visa'));
      expect(seed, copy);
    });

    test('Pin24Exception.toString carries code and message', () {
      expect(
        const Pin24Exception('X', 'y').toString(),
        'Pin24Exception(X): y',
      );
    });
  });

  group('PIN 24 UI derivation vectors', () {
    final meta = (uiDerivation['meta'] as Map).cast<String, dynamic>();
    final seeds = <String, Uint8List>{};
    Uint8List uiSeed(String name, [String passphrase = '']) {
      final phrase = switch (name) {
        'abandon12' => _abandon12,
        'speculos24' => _speculos,
        _ => fail('unknown seed $name'),
      };
      return seeds.putIfAbsent(
        '$name\u0000$passphrase',
        () => bip39ToSeed(phrase, passphrase: passphrase),
      );
    }

    test('UI constants', () {
      final toggles = [
        for (final t in meta['PWD_TOGGLES'] as List)
          _parseHexInt((t as Map)['bits_hex'] as String),
      ];
      expect(toggles, [kUppercase, kLowercase, kNumbers, kBars, kExtSymbols]);
      expect(meta['DEFAULT_MIN_SET'], kDefaultMinSet);
      expect(meta['SETS'], kCharsets);
      expect(meta['MAX_LENGTH'], kPinMaxLength);
      expect(meta['MIN_LENGTH'], 1);
      expect(meta['SUPPORTED_WORD_COUNTS'], kSupportedWordCounts);
    });

    test('PIN mode: full password and PINs 1..12', () {
      final pinMode =
          (uiDerivation['pin_mode'] as List).cast<Map<String, dynamic>>();
      expect(pinMode, hasLength(25));
      for (final v in pinMode) {
        final seed =
            uiSeed(v['seed'] as String, (v['passphrase'] as String?) ?? '');
        final nickname = v['nickname'] as String;
        final full = v['full_numbers_separators_20'] as String;
        expect(derivePassword(bip39Seed: seed, nickname: nickname), full,
            reason: nickname);
        if (v.containsKey('digit_count')) {
          expect(
            full.codeUnits.where((c) => c >= 0x30 && c <= 0x39).length,
            v['digit_count'],
          );
        }
        (v['pins'] as Map).forEach((len, pin) {
          final d = derivePinDetailed(
            bip39Seed: seed,
            nickname: nickname,
            length: int.parse(len as String),
          );
          expect(d.pin, pin, reason: '$nickname L=$len');
          expect(d.fullPassword, full);
        });
      }
    });

    test('Password mode: all 31 toggle combinations', () {
      final pwd = (uiDerivation['password_mode_ui_reachable'] as List)
          .cast<Map<String, dynamic>>();
      expect(pwd, hasLength(31));
      for (final v in pwd) {
        expect(
          derivePassword(
            bip39Seed: uiSeed(v['seed'] as String),
            nickname: v['nickname'] as String,
            setMask: _parseHexInt(v['set_mask_hex'] as String),
          ),
          v['password'],
          reason: v['set_mask_hex'] as String,
        );
      }
    });

    test('zero-padding examples', () {
      for (final v in (uiDerivation['padding_examples'] as List)
          .cast<Map<String, dynamic>>()) {
        final seed = uiSeed(v['seed'] as String);
        final nickname = v['nickname'] as String;
        final d =
            derivePinDetailed(bip39Seed: seed, nickname: nickname, length: 12);
        expect(d.fullPassword, v['full']);
        expect(d.pin, v['pin12']);
        expect(d.isPadded, isTrue);
        expect(d.digitsInOutput + d.paddedZeros, 12);
        expect(d.pin.substring(d.digitsInOutput), '0' * d.paddedZeros);
      }
    });
  });

  group('verifier regressions', () {
    final reg = _load('pin24_regressions.json');
    final nfkdDoc = _load('pin24_nfkd_py16.json');
    final abandonSeed = _unhex(
      (reg['meta'] as Map)['mnemonic_seed_hex'] as String,
    );

    test('fixtures come from Python with Unicode 16.0.0', () {
      expect((reg['meta'] as Map)['unidata_version'], '16.0.0');
      expect((nfkdDoc['meta'] as Map)['unidata_version'], '16.0.0');
    });

    for (final v
        in (reg['nfkd_vectors'] as List).cast<Map<String, dynamic>>()) {
      test('NFKD shim vector ${v['id']}', () {
        final pp = _str(v['passphrase_cps']);
        final mnemonic = v['mnemonic'] as String;
        final nickname = v['nickname'] as String;
        // The vector really exercises the shim: plain unorm would differ.
        expect(unorm.nfkd(pp), isNot(pythonNfkd(pp)));
        expect(pythonNfkd(pp).runes.toList(), v['nfkd_cps']);
        expect(_hex(utf8.encode(pythonNfkd(pp))), v['nfkd_utf8_hex']);
        final seed = bip39ToSeed(mnemonic, passphrase: pp);
        expect(_hex(seed), v['seed_hex']);
        expect(
            derivePassword(bip39Seed: seed, nickname: nickname), v['password']);
        expect(
          derivePin(
            seedPhrase: mnemonic,
            nickname: nickname,
            length: 8,
            bip39Passphrase: pp,
          ),
          v['pin8'],
        );
      });
    }

    for (final e in (reg['nfkd_errors'] as List).cast<Map<String, dynamic>>()) {
      test('NFKD error position ${e['id']}', () {
        _expectPin24Error(
          'bip39_to_seed',
          {'phrase': e['mnemonic'], 'passphrase': _str(e['passphrase_cps'])},
          Pin24Exception.passphraseNotUtf8,
          e['message'] as String,
        );
      });
    }

    test(
        'pythonNfkd == Python NFKD for every code point, alone and in '
        'canonical-reordering probes', () {
      final table = <int, List<int>>{
        for (final e in (nfkdDoc['nfkd'] as Map).entries)
          int.parse(e.key as String, radix: 16): [
            for (final h in (e.value as String).split(','))
              int.parse(h, radix: 16),
          ],
      };
      expect(table, hasLength((nfkdDoc['meta'] as Map)['nfkd_entries']));
      final ccc = <int, int>{};
      for (final r in (nfkdDoc['ccc'] as List).cast<List<dynamic>>()) {
        for (var cp = r[0] as int; cp <= (r[1] as int); cp++) {
          ccc[cp] = r[2] as int;
        }
      }
      expect(ccc[0x0334], 1);
      expect(ccc[0x0345], 240);

      // UAX #15: full decomposition of each code point (table, or the
      // algorithmic Hangul syllables), then a stable sort of every run of
      // non-starters by combining class.
      List<int> decompose(int cp) {
        final d = table[cp];
        if (d != null) return d;
        if (cp >= 0xAC00 && cp <= 0xD7A3) {
          final s = cp - 0xAC00;
          return [
            0x1100 + s ~/ 588,
            0x1161 + (s % 588) ~/ 28,
            if (s % 28 != 0) 0x11A7 + s % 28,
          ];
        }
        return [cp];
      }

      List<int> reference(List<int> cps) {
        final out = [for (final cp in cps) ...decompose(cp)];
        for (var i = 1; i < out.length; i++) {
          final k = ccc[out[i]] ?? 0;
          if (k == 0) continue;
          var j = i;
          while (j > 0) {
            final prev = ccc[out[j - 1]] ?? 0;
            if (prev == 0 || prev <= k) break;
            final t = out[j - 1];
            out[j - 1] = out[j];
            out[j] = t;
            j--;
          }
        }
        return out;
      }

      bool same(String got, List<int> want) {
        final r = got.runes.toList();
        if (r.length != want.length) return false;
        for (var i = 0; i < r.length; i++) {
          if (r[i] != want[i]) return false;
        }
        return true;
      }

      final bad = <String>[];
      final unormDivergent = <int>{};
      final ovl = String.fromCharCode(0x0334);
      final ypo = String.fromCharCode(0x0345);
      for (var cp = 0; cp < 0x110000 && bad.length < 20; cp++) {
        if (cp >= 0xD800 && cp <= 0xDFFF) continue;
        final c = String.fromCharCode(cp);
        final hex = 'U+${cp.toRadixString(16)}';
        if (!same(pythonNfkd(c), decompose(cp))) bad.add('alone $hex');
        final probe1 = reference([0x41, cp, 0x0334]);
        if (!same(pythonNfkd('A$c$ovl'), probe1)) bad.add('A c 0334 $hex');
        if (!same(pythonNfkd('A$ypo$c'), reference([0x41, 0x0345, cp]))) {
          bad.add('A 0345 c $hex');
        }
        if (!same(unorm.nfkd('A$c$ovl'), probe1) ||
            !same(unorm.nfkd(c), decompose(cp))) {
          unormDivergent.add(cp);
        }
      }
      expect(bad, isEmpty);
      // The shim covers exactly the code points plain unorm_dart 0.3.2 gets
      // wrong. If this fails after a unorm_dart upgrade, revisit the list in
      // ledger_pin24.dart (e.g. once yshrsmz/unorm-dart#84 is fixed).
      expect(unormDivergent, {
        for (var cp = 0x1ACF; cp <= 0x1ADD; cp++) cp,
        for (var cp = 0x1AE0; cp <= 0x1AEB; cp++) cp,
        0xA7F1, 0xD7A4, 0x10EFA, 0x10EFB, //
        0x1E6E3, 0x1E6E6, 0x1E6EE, 0x1E6EF, 0x1E6F5,
      });
    }, timeout: const Timeout(Duration(minutes: 5)));

    test(
        'pythonNfkd keeps lone surrogates and splits around shimmed code '
        'points', () {
      final d800 = String.fromCharCode(0xD800);
      expect(pythonNfkd(''), '');
      expect(pythonNfkd('힤$d800').codeUnits, [0xD7A4, 0xD800]);
      expect(pythonNfkd('ﬁ힤ﬁ'), 'fi힤fi');
      expect(pythonNfkd('\u{1E6F5}'), '\u{1E6F5}');
      expect(pythonNfkd('é꟱é'), 'é꟱é');
    });

    for (final c in [
      ...(reg['size_errors'] as List).cast<Map<String, dynamic>>(),
      ...(reg['overflow_errors'] as List).cast<Map<String, dynamic>>(),
    ]) {
      test('size/minimums ${c['id']}', () {
        final message = c['message'] as String;
        final code = message.startsWith('rng_u8_modulo')
            ? Pin24Exception.moduloRange
            : Pin24Exception.minExceedsSize;
        final sw = Stopwatch()..start();
        _expectPin24Error(
          'derive_password',
          {
            'bip39_seed_hex': _hex(abandonSeed),
            'nickname': 'visa',
            'set_mask': c['set_mask'],
            'min_from_set': c['min_from_set'],
            'size': c['size'],
          },
          code,
          message,
        );
        expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      });
    }

    test('size > 256 is decided before any allocation or draw', () {
      final drbg = CtrDrbg.instantiate(Uint8List(32));
      expect(
        () => sampleUnshuffled(
          drbg,
          setMask: kPinMask,
          minFromSet: kDefaultMinSet,
          size: 100000,
        ),
        throwsA(_pin24Error(Pin24Exception.moduloRange)),
      );
      expect(drbg.generateCalls, 0);
      expect(
        () => sampleUnshuffled(
          drbg,
          setMask: 0x03,
          minFromSet: const [0x7FFFFFFFFFFFFFFF, 1, 0, 0, 0, 0, 0, 0],
          size: 1 << 40,
        ),
        throwsA(_pin24Error(Pin24Exception.minExceedsSize)),
      );
      expect(drbg.generateCalls, 0);
      final sw = Stopwatch()..start();
      expect(
        () => derivePassword(
          bip39Seed: abandonSeed,
          nickname: 'visa',
          size: 1 << 30,
        ),
        throwsA(_pin24Error(Pin24Exception.moduloRange)),
      );
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      // Exactly 256 still works (shuffle modulo 256 is allowed).
      expect(
        derivePassword(bip39Seed: abandonSeed, nickname: 'visa', size: 256),
        hasLength(256),
      );
    });

    test('huge minimums give MIN_EXCEEDS_SIZE, never a RangeError', () {
      const big = 0x7FFFFFFFFFFFFFFF;
      for (final (mins, size) in [
        (const [1, big, 0, 0, 0, 0, 0, 0], 20),
        (const [big, 0, 0, 0, 0, 0, 0, 0], 1),
        (const [big, big, 0, 0, 0, 0, 0, 0], 256),
      ]) {
        final drbg = CtrDrbg.instantiate(Uint8List(32));
        expect(
          () => sampleUnshuffled(
            drbg,
            setMask: 0x03,
            minFromSet: mins,
            size: size,
          ),
          throwsA(_pin24Error(Pin24Exception.minExceedsSize)),
        );
      }
    });

    test('toString withholds the message of *_NOT_UTF8 errors', () {
      final d800 = String.fromCharCode(0xD800);
      final dc00 = String.fromCharCode(0xDC00);
      final errors = <Pin24Exception>[];
      for (final f in [
        () => bip39ToSeed(_abandon12, passphrase: 'secret$d800'),
        () => derivePassword(bip39Seed: abandonSeed, nickname: 'visa$dc00'),
      ]) {
        try {
          f();
          fail('expected Pin24Exception');
        } on Pin24Exception catch (e) {
          errors.add(e);
        }
      }
      expect(errors.map((e) => e.code), [
        Pin24Exception.passphraseNotUtf8,
        Pin24Exception.nicknameNotUtf8,
      ]);
      expect(
        errors[0].message,
        "'utf-8' codec can't encode character '\\ud800' in position 14: "
        'surrogates not allowed',
      );
      for (final e in errors) {
        expect(e.messageQuotesInput, isTrue);
        expect(e.message, contains('position'));
        expect(e.toString(), startsWith('Pin24Exception(${e.code})'));
        expect(e.toString(), isNot(contains('position')));
        expect(e.toString(), isNot(contains(e.message)));
      }
      const plain = Pin24Exception(Pin24Exception.moduloRange, 'm');
      expect(plain.messageQuotesInput, isFalse);
      expect(plain.toString(), 'Pin24Exception(MODULO_RANGE): m');
    });

    test('WipeableAesEngine zeroes old schedules on re-key and on wipe', () {
      final a = (primitives['aes256_ecb_nist'] as Map).cast<String, dynamic>();
      final k1 = _unhex(a['key_hex'] as String);
      final k2 = Uint8List.fromList(List.generate(32, (i) => 255 - i));
      final spy = _SpyAes()..init(true, KeyParameter(k1));
      final out = Uint8List(16);
      spy.processBlock(_unhex(a['plaintext_hex'] as String), 0, out, 0);
      expect(_hex(out), a['ciphertext_hex']);
      expect(_allZero(spy.schedules.single), isFalse);

      spy.init(true, KeyParameter(k2));
      expect(spy.schedules, hasLength(2));
      expect(_allZero(spy.schedules[0]), isTrue);
      expect(_allZero(spy.schedules[1]), isFalse);
      spy.wipeKeySchedule();
      expect(_allZero(spy.schedules[1]), isTrue);
      spy.wipeKeySchedule(); // idempotent

      // After wiping, the output no longer depends on the key.
      final e1 = WipeableAesEngine()..init(true, KeyParameter(k1));
      final e2 = WipeableAesEngine()..init(true, KeyParameter(k2));
      final block = Uint8List.fromList(List.generate(16, (i) => i));
      final o1 = Uint8List(16);
      final o2 = Uint8List(16);
      e1.processBlock(block, 0, o1, 0);
      e2.processBlock(block, 0, o2, 0);
      expect(o1, isNot(o2));
      e1.wipeKeySchedule();
      e2.wipeKeySchedule();
      e1.processBlock(block, 0, o1, 0);
      e2.processBlock(block, 0, o2, 0);
      expect(o1, o2);
    });

    for (final d in (reg['normalize_divergences'] as List)
        .cast<Map<String, dynamic>>()) {
      test(
          'lower() divergence ${d['id']}: a-z projection and validity match '
          'Python', () {
        final input = _str(d['input_cps']);
        final pyNormalized = _str(d['normalized_cps']);
        final normalized = normalizeSeedPhrase(input);
        String az(String s) => s.replaceAll(RegExp('[^a-z]+'), ' ');
        expect(az(normalized), az(pyNormalized));
        expect(
          bip39ChecksumValid(pythonNfkd(normalized).split(' ')),
          d['bip39_check'],
        );
        if (d['bip39_check'] == false) {
          expect(() => bip39ToSeed(input),
              throwsA(_pin24Error(Pin24Exception.bip39Invalid)));
        }
        final parsed = parseSeedWords(input);
        expect(parsed.words, d['ui_words']);
        expect(parsed.invalidPositions, d['ui_bad']);
        expect(parsed.partialPositions, d['ui_partial']);
      });
    }

    test('the divergence fixture really diverges from Dart lower()', () {
      final diverging = [
        for (final d in (reg['normalize_divergences'] as List)
            .cast<Map<String, dynamic>>())
          if (normalizeSeedPhrase(_str(d['input_cps'])) !=
              _str(d['normalized_cps']))
            d['id'],
      ];
      expect(diverging, isNotEmpty);
    });
  });

  // Trace A9.2: where the Dart-only PASSPHRASE_NOT_UTF8 and the
  // MIN_FROM_SET_LENGTH checks sit in the check order.
  group('check order (Dart additions)', () {
    const good = 'abandon abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon abandon about';
    const bad = 'abandon abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon abandon abandon';
    final surrogate = String.fromCharCode(0xD800);

    String code(void Function() f) {
      try {
        f();
      } on Pin24Exception catch (e) {
        return e.code;
      }
      return 'ok';
    }

    test('BIP39_INVALID before PASSPHRASE_NOT_UTF8', () {
      expect(
        code(() => derivePassword(
            seedPhrase: bad, nickname: 'x', bip39Passphrase: surrogate)),
        Pin24Exception.bip39Invalid,
      );
    });

    test('PASSPHRASE_NOT_UTF8 before NICKNAME_EMPTY and SIZE_NOT_POSITIVE', () {
      expect(
        code(() => derivePassword(
            seedPhrase: good, nickname: '', bip39Passphrase: surrogate)),
        Pin24Exception.passphraseNotUtf8,
      );
      expect(
        code(() => derivePassword(
            seedPhrase: good,
            nickname: 'x',
            bip39Passphrase: surrogate,
            size: 0)),
        Pin24Exception.passphraseNotUtf8,
      );
    });

    test('PIN_LENGTH_NOT_POSITIVE before the passphrase is looked at', () {
      expect(
        code(() => derivePin(
            seedPhrase: good,
            nickname: 'x',
            bip39Passphrase: surrogate,
            length: 0)),
        Pin24Exception.pinLengthNotPositive,
      );
    });

    test('MIN_FROM_SET_LENGTH before MIN_EXCEEDS_SIZE', () {
      expect(
        code(() => derivePassword(
            bip39Seed: Uint8List(64),
            nickname: 'x',
            setMask: 0xFF,
            minFromSet: const [99, 0, 0, 0, 0, 0, 0],
            size: 20)),
        Pin24Exception.minFromSetLength,
      );
      // With the right length the size check is what fails.
      expect(
        code(() => derivePassword(
            bip39Seed: Uint8List(64),
            nickname: 'x',
            setMask: 0xFF,
            minFromSet: const [99, 0, 0, 0, 0, 0, 0, 0],
            size: 20)),
        Pin24Exception.minExceedsSize,
      );
    });
  });
}
