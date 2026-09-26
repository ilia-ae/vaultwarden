// TEMPORARY differential harness (independent verifier). Delete after use.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;
import 'package:vault_approver/pin_tools/bip39.dart';
import 'package:vault_approver/pin_tools/ledger_pin24.dart';

const _dir =
    '/private/tmp/claude-501/-Users-ilya-CODE-vaultwarden/fc401efa-332a-4a8e-a761-97ec2c64ab4b/scratchpad/diff/pin24';

final String _casesPath =
    Platform.environment['PIN24_CASES'] ?? '$_dir/cases.json';
final String _mismatchPath =
    Platform.environment['PIN24_MISMATCHES'] ?? '$_dir/mismatches.json';

late Map<String, dynamic> data;
final Map<String, List<Object?>> mism = {};
final Map<String, Object?> stats = {};

void _bad(String section, Object? rec) {
  (mism[section] ??= []).add(rec);
}

Uint8List _unhex(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Map<Symbol, dynamic> _named(Map<String, dynamic> a) {
  final m = <Symbol, dynamic>{};
  a.forEach((k, v) {
    switch (k) {
      case 'seed_phrase':
        m[#seedPhrase] = v as String;
      case 'bip39_seed_hex':
        m[#bip39Seed] = _unhex(v as String);
      case 'nickname':
        m[#nickname] = v as String;
      case 'set_mask':
        m[#setMask] = v as int;
      case 'min_from_set':
        m[#minFromSet] = (v as List).cast<int>();
      case 'size':
        m[#size] = v as int;
      case 'length':
        m[#length] = v as int;
      case 'bip39_passphrase':
        m[#bip39Passphrase] = v as String;
      default:
        throw StateError('unknown arg $k');
    }
  });
  return m;
}

Map<String, Object?> _capture(Object? Function() f) {
  try {
    return {'ok': f()};
  } on Pin24Exception catch (e) {
    return {'err': e.code, 'msg': e.message};
  } catch (e) {
    return {'err': 'DART:${e.runtimeType}', 'msg': e.toString()};
  }
}

bool _sameResult(Map<String, dynamic> exp, Map<String, Object?> got) {
  if (exp.containsKey('ok')) {
    return got.containsKey('ok') && got['ok'] == exp['ok'];
  }
  return got['err'] == exp['err'] && got['msg'] == exp['msg'];
}

bool _listEq(List<Object?> a, List<Object?> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _cps(String s) =>
    s.runes.map((r) => r.toRadixString(16).padLeft(4, '0')).join(' ');

final RegExp _nonAz = RegExp('[^a-z]+');
String _azProjection(String s) => s.replaceAll(_nonAz, ' ');
bool _allAz(String s) => s.isNotEmpty && !s.contains(RegExp('[^a-z]'));

void main() {
  setUpAll(() {
    data = jsonDecode(File(_casesPath).readAsStringSync())
        as Map<String, dynamic>;
  });

  tearDownAll(() {
    final out = {
      'cases': _casesPath,
      'counts': {for (final e in mism.entries) e.key: e.value.length},
      'stats': stats,
      'mismatches': mism,
    };
    File(_mismatchPath)
        .writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
  });

  const long = Timeout(Duration(minutes: 40));

  test('derive_password', () {
    final cases = (data['derive'] as List).cast<Map<String, dynamic>>();
    final sw = Stopwatch()..start();
    for (final c in cases) {
      final args = (c['args'] as Map).cast<String, dynamic>();
      final got = _capture(
        () => Function.apply(derivePassword, const [], _named(args)),
      );
      final exp = (c['expect'] as Map).cast<String, dynamic>();
      if (!_sameResult(exp, got)) {
        _bad('derive', {'id': c['id'], 'args': args, 'py': exp, 'dart': got});
      }
    }
    stats['derive_n'] = cases.length;
    stats['derive_ms'] = sw.elapsedMilliseconds;
    expect(mism['derive'] ?? const [], isEmpty);
  }, timeout: long);

  test('derive_pin (+ derivePinDetailed)', () {
    final cases = (data['pin'] as List).cast<Map<String, dynamic>>();
    for (final c in cases) {
      final args = (c['args'] as Map).cast<String, dynamic>();
      final exp = (c['expect'] as Map).cast<String, dynamic>();
      final detailed = _capture(
        () => Function.apply(derivePinDetailed, const [], _named(args)),
      );
      final got = detailed.containsKey('ok')
          ? {'ok': (detailed['ok']! as PinDerivation).pin}
          : detailed;
      if (!_sameResult(exp, got)) {
        _bad('pin', {'id': c['id'], 'args': args, 'py': exp, 'dart': got});
        continue;
      }
      if (detailed.containsKey('ok')) {
        final d = detailed['ok']! as PinDerivation;
        final full = exp['full'] as String;
        final digits = full.codeUnits.where((u) => u >= 48 && u <= 57).length;
        final len = args['length'] as int;
        final pad = digits >= len ? 0 : len - digits;
        if (d.fullPassword != full ||
            d.digitsInOutput != digits ||
            d.paddedZeros != pad ||
            d.isPadded != (pad > 0)) {
          _bad('pin_detail', {
            'id': c['id'],
            'full_py': full,
            'full_dart': d.fullPassword,
            'digits': [digits, d.digitsInOutput],
            'pad': [pad, d.paddedZeros],
          });
        }
      }
      // derivePin itself (raw-seed only, to avoid doubling PBKDF2 time).
      if (!args.containsKey('seed_phrase')) {
        final g2 = _capture(
          () => Function.apply(derivePin, const [], _named(args)),
        );
        if (!_sameResult(exp, g2)) {
          _bad('pin_plain', {'id': c['id'], 'py': exp, 'dart': g2});
        }
      }
    }
    stats['pin_n'] = cases.length;
    expect(mism['pin'] ?? const [], isEmpty);
    expect(mism['pin_detail'] ?? const [], isEmpty);
    expect(mism['pin_plain'] ?? const [], isEmpty);
  }, timeout: long);

  test('bip39_to_seed + normalize + check', () {
    final cases = (data['seed'] as List).cast<Map<String, dynamic>>();
    final sw = Stopwatch()..start();
    var pbkdf2 = 0;
    for (final c in cases) {
      final phrase = c['phrase'] as String;
      final pp = c['passphrase'] as String;
      final exp = (c['expect'] as Map).cast<String, dynamic>();
      final got = _capture(() => _hex(bip39ToSeed(phrase, passphrase: pp)));
      if (got.containsKey('ok')) pbkdf2++;
      if (!_sameResult(exp, got)) {
        _bad('seed', {
          'id': c['id'],
          'phrase': phrase,
          'pp': pp,
          'pp_cps': _cps(pp),
          'py': exp,
          'dart': got,
        });
      }
      final norm = _capture(() => normalizeSeedPhrase(phrase));
      if (norm['ok'] != c['normalized']) {
        _bad('seed_normalize', {
          'id': c['id'],
          'in': phrase,
          'py': c['normalized'],
          'dart': norm,
        });
      }
      final chk = _capture(
        () => bip39ChecksumValid(
          unorm.nfkd(normalizeSeedPhrase(phrase)).split(' '),
        ),
      );
      if (chk['ok'] != c['check']) {
        _bad('seed_check', {'id': c['id'], 'py': c['check'], 'dart': chk});
      }
    }
    stats['seed_n'] = cases.length;
    stats['seed_ms'] = sw.elapsedMilliseconds;
    stats['seed_pbkdf2'] = pbkdf2;
    expect(mism['seed'] ?? const [], isEmpty);
    expect(mism['seed_normalize'] ?? const [], isEmpty);
    expect(mism['seed_check'] ?? const [], isEmpty);
  }, timeout: long);

  test('normalize_seed_phrase', () {
    final cases = (data['normalize'] as List).cast<Map<String, dynamic>>();
    for (final c in cases) {
      final s = c['in'] as String;
      final got = _capture(() => normalizeSeedPhrase(s));
      if (got['ok'] != c['out']) {
        _bad('normalize', {
          'in': s,
          'in_cps': _cps(s),
          'py': c['out'],
          'dart': got,
          'az_differs': got['ok'] is String &&
              _azProjection(got['ok']! as String) !=
                  _azProjection(c['out'] as String),
        });
      }
      final chk = _capture(
        () => bip39ChecksumValid(unorm.nfkd(normalizeSeedPhrase(s)).split(' ')),
      );
      if (chk['ok'] != c['check']) {
        _bad('normalize_check', {'in': s, 'py': c['check'], 'dart': chk});
      }
    }
    stats['normalize_n'] = cases.length;
    expect(mism['normalize_check'] ?? const [], isEmpty);
  }, timeout: long);

  test('UI parser / validate / target', () {
    final cases = (data['parser'] as List).cast<Map<String, dynamic>>();
    for (final c in cases) {
      final t = c['in'] as String;
      final p = parseSeedWords(t);
      final v = validateWords(p.words);
      final ok = _listEq(p.words, c['words'] as List) &&
          _listEq(p.invalidPositions, c['bad'] as List) &&
          _listEq(p.partialPositions, c['partial'] as List) &&
          v.isValid == c['valid'] &&
          v.message == c['msg'] &&
          targetWordCount(p.words.length) == c['target'] &&
          p.canonical == (c['words'] as List).join(' ');
      if (!ok) {
        _bad('parser', {
          'in': t,
          'in_cps': _cps(t),
          'py': {
            'words': c['words'],
            'bad': c['bad'],
            'partial': c['partial'],
            'valid': c['valid'],
            'msg': c['msg'],
            'target': c['target'],
          },
          'dart': {
            'words': p.words,
            'bad': p.invalidPositions,
            'partial': p.partialPositions,
            'valid': v.isValid,
            'msg': v.message,
            'target': targetWordCount(p.words.length),
          },
        });
      }
    }
    final target = (data['target'] as Map).cast<String, dynamic>();
    target.forEach((k, v) {
      if (targetWordCount(int.parse(k)) != v) {
        _bad('target', {'n': k, 'py': v, 'dart': targetWordCount(int.parse(k))});
      }
    });
    stats['parser_n'] = cases.length;
    expect(mism['parser'] ?? const [], isEmpty);
    expect(mism['target'] ?? const [], isEmpty);
  }, timeout: long);

  test('suggestions', () {
    final cases = (data['suggest'] as List).cast<Map<String, dynamic>>();
    for (final c in cases) {
      final prefix = c['prefix'] as String;
      final lim = c['limit'] as int?;
      final got = lim == null
          ? suggestionsForPrefix(prefix)
          : suggestionsForPrefix(prefix, limit: lim);
      if (!_listEq(got, c['out'] as List)) {
        _bad('suggest', {'prefix': prefix, 'limit': lim, 'py': c['out'], 'dart': got});
      }
    }
    expect(mism['suggest'] ?? const [], isEmpty);
  }, timeout: long);

  test('checksum / validateWords', () {
    final cases = (data['check'] as List).cast<Map<String, dynamic>>();
    for (final c in cases) {
      final words = (c['words'] as List).cast<String>();
      final v = validateWords(words);
      if (bip39ChecksumValid(words) != c['check'] ||
          v.isValid != c['valid'] ||
          v.message != c['msg']) {
        _bad('check', {
          'words': words,
          'py': [c['check'], c['valid'], c['msg']],
          'dart': [bip39ChecksumValid(words), v.isValid, v.message],
        });
      }
    }
    expect(mism['check'] ?? const [], isEmpty);
  }, timeout: long);

  test('UI flow (parse -> validate -> derive)', () {
    final cases = (data['ui_flow'] as List).cast<Map<String, dynamic>>();
    for (final c in cases) {
      final p = parseSeedWords(c['text'] as String);
      final v = validateWords(p.words);
      if (v.isValid != c['valid']) {
        _bad('ui_flow', {'id': c['id'], 'valid': [c['valid'], v.isValid]});
        continue;
      }
      final exp = (c['expect'] as Map?)?.cast<String, dynamic>();
      if (exp == null) continue;
      final Map<String, Object?> got;
      if (c['mode'] == 'pin') {
        got = _capture(
          () => derivePin(
            seedPhrase: p.canonical,
            nickname: c['nickname'] as String,
            length: c['length'] as int,
            bip39Passphrase: c['passphrase'] as String,
          ),
        );
      } else {
        got = _capture(
          () => derivePassword(
            seedPhrase: p.canonical,
            nickname: c['nickname'] as String,
            setMask: c['mask'] as int,
            minFromSet: kDefaultMinSet,
            bip39Passphrase: c['passphrase'] as String,
          ),
        );
      }
      if (!_sameResult(exp, got)) {
        _bad('ui_flow', {'id': c['id'], 'py': exp, 'dart': got});
      }
    }
    expect(mism['ui_flow'] ?? const [], isEmpty);
  }, timeout: long);

  test('exhaustive per-code-point lower / NFKD / reorder probes', () {
    final lowerMap = (data['lower_map'] as Map).cast<String, dynamic>();
    final nfkdMap = (data['nfkd_map'] as Map).cast<String, dynamic>();
    final probe1 = (data['probe1'] as Map).cast<String, dynamic>();
    final probe2 = (data['probe2'] as Map).cast<String, dynamic>();
    final ovl = String.fromCharCode(0x0334);
    final ypo = String.fromCharCode(0x0345);
    var lowerDiff = 0, lowerAz = 0, nfkdDiff = 0, p1Diff = 0, p2Diff = 0;
    for (var cp = 0; cp <= 0x10FFFF; cp++) {
      final s = String.fromCharCode(cp);
      final key = '$cp';
      // lower
      final pyLower = (lowerMap[key] as String?) ?? s;
      final dLower = pythonLower(s);
      if (dLower != pyLower) {
        lowerDiff++;
        final pyF = unorm.nfkd(pyLower);
        final dF = unorm.nfkd(dLower);
        final az = _azProjection(pyLower) != _azProjection(dLower) ||
            _allAz(pyF) != _allAz(dF) ||
            (_allAz(pyF) && pyF != dF);
        if (az) lowerAz++;
        if (az || lowerDiff <= 40) {
          _bad(az ? 'lower_az' : 'lower_other', {
            'cp': cp.toRadixString(16),
            'py': _cps(pyLower),
            'dart': _cps(dLower),
          });
        }
      }
      // nfkd
      final pyN = (nfkdMap[key] as String?) ?? s;
      final Map<String, Object?> dN = _capture(() => unorm.nfkd(s));
      if (dN['ok'] != pyN) {
        nfkdDiff++;
        _bad('nfkd', {
          'cp': cp.toRadixString(16),
          'py': _cps(pyN),
          'dart': dN['ok'] is String ? _cps(dN['ok']! as String) : dN,
        });
      }
      final e1 = (probe1[key] as String?) ?? 'A$pyN$ovl';
      final g1 = _capture(() => unorm.nfkd('A$s$ovl'));
      if (g1['ok'] != e1) {
        p1Diff++;
        _bad('probe1', {
          'cp': cp.toRadixString(16),
          'py': _cps(e1),
          'dart': g1['ok'] is String ? _cps(g1['ok']! as String) : g1,
        });
      }
      final e2 = (probe2[key] as String?) ?? 'A$ypo$pyN';
      final g2 = _capture(() => unorm.nfkd('A$ypo$s'));
      if (g2['ok'] != e2) {
        p2Diff++;
        _bad('probe2', {
          'cp': cp.toRadixString(16),
          'py': _cps(e2),
          'dart': g2['ok'] is String ? _cps(g2['ok']! as String) : g2,
        });
      }
    }
    stats['cp'] = {
      'lower_diff': lowerDiff,
      'lower_affects_az': lowerAz,
      'nfkd_diff': nfkdDiff,
      'probe1_diff': p1Diff,
      'probe2_diff': p2Diff,
    };
  }, timeout: long);

  test('perf', () {
    final seed = Uint8List.fromList(List<int>.generate(64, (i) => i * 7));
    int timeIt(int size, int reps) {
      final sw = Stopwatch()..start();
      for (var i = 0; i < reps; i++) {
        derivePassword(
          bip39Seed: seed,
          nickname: 'n$i',
          setMask: 0xFF,
          minFromSet: const [0, 0, 0, 0, 0, 0, 0, 0],
          size: size,
        );
      }
      return sw.elapsedMicroseconds ~/ reps;
    }

    timeIt(256, 20); // warm-up
    final t20 = timeIt(20, 200);
    final t256 = timeIt(256, 200);
    final sw = Stopwatch()..start();
    for (var i = 0; i < 10; i++) {
      bip39ToSeed(
        'abandon abandon abandon abandon abandon abandon abandon abandon '
        'abandon abandon abandon about',
        passphrase: 'p$i',
      );
    }
    final tSeed = sw.elapsedMicroseconds ~/ 10;
    final bigText = List.generate(20000, (i) => 'zzqx$i').join(' ');
    final sw2 = Stopwatch()..start();
    parseSeedWords(bigText);
    final tParseBig = sw2.elapsedMilliseconds;
    stats['perf_us'] = {
      'derive_size20': t20,
      'derive_size256': t256,
      'bip39ToSeed': tSeed,
      'parse_20000_junk_words_ms': tParseBig,
    };
  }, timeout: long);
}
