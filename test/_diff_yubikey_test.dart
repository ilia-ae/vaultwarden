// TEMPORARY differential test (fixer re-run). Deleted after the run.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/pin_tools/python_text.dart';
import 'package:vault_approver/pin_tools/yubikey_secrets.dart';

const _dir = '/private/tmp/claude-501/-Users-ilya-CODE-vaultwarden/'
    'fc401efa-332a-4a8e-a761-97ec2c64ab4b/scratchpad/diff/yubikey';

Uint8List _hex(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return out;
}

String _toHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Object? _canon(Object? o) {
  if (o is Map) {
    final keys = o.keys.map((k) => k.toString()).toList()..sort();
    return {for (final k in keys) k: _canon(o[k])};
  }
  if (o is List) return [for (final e in o) _canon(e)];
  return o;
}

bool _same(Object? a, Object? b) =>
    jsonEncode(_canon(a)) == jsonEncode(_canon(b));

Map<String, Object?> _err(Object e) => switch (e) {
      YkException(:final code) => {'error': code},
      ArgumentError() => {'error': 'ArgumentError'},
      _ => {'error': 'UNEXPECTED ${e.runtimeType}: $e'},
    };

bool _formula(String s) => s.isNotEmpty && '=+-@\t\r'.contains(s[0]);
bool _unsafe(String s) =>
    s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r');

class _Report {
  final counts = <String, int>{};
  final mismatchCounts = <String, int>{};
  final mismatches = <String, List<Object?>>{};
  final divergences = <String, int>{};

  void count(String cat) => counts[cat] = (counts[cat] ?? 0) + 1;
  void diverge(String what) => divergences[what] = (divergences[what] ?? 0) + 1;

  void check(String cat, Object? got, Object? want, Object? input) {
    count(cat);
    if (_same(got, want)) return;
    mismatchCounts[cat] = (mismatchCounts[cat] ?? 0) + 1;
    final l = mismatches.putIfAbsent(cat, () => []);
    if (l.length < 20) l.add({'input': input, 'got': got, 'want': want});
  }

  int get total => mismatchCounts.values.fold(0, (a, b) => a + b);

  Map<String, Object?> toJson() => {
        'counts': counts,
        'mismatch_counts': mismatchCounts,
        'divergences': divergences,
        'mismatches': mismatches,
      };
}

Set<YkPhase> _phases(Iterable<String> names) =>
    {for (final n in names) YkPhase.values.byName(n)};

/// Script-order emulation of main(): master once, then every key, then the
/// export. Returns the resolved keys too (null if resolution failed).
({Map<String, Object?> out, List<YkKeySecrets>? keys, int draws}) _runMain({
  required String mode,
  required Uint8List raw,
  required Set<YkPhase> phases,
  required bool otpFromSerial,
  required List<({String serial, Map<String, String> manual})> keys,
  List<List<int>> log = const [],
}) {
  var idx = 0;
  int replay(int max) {
    if (idx >= log.length) throw StateError('extra draw (bound $max)');
    final e = log[idx++];
    if (e[0] != max) throw StateError('bound $max, script drew from ${e[0]}');
    return e[1];
  }

  List<YkKeySecrets>? resolved;
  try {
    final m = mode == 'derived' ? ykNormalizeMasterKey(raw) : null;
    resolved = [
      for (final k in keys)
        ykResolveKey(
          serial: k.serial,
          phases: phases,
          mode: mode == 'derived' ? YkMode.derived : YkMode.random,
          master: m,
          otpFromSerial: otpFromSerial,
          manual: k.manual,
          nextIntForTest: replay,
        ),
    ];
    return (
      out: {'csv': ykBitwardenCsv(resolved)},
      keys: resolved,
      draws: idx,
    );
  } on YkException catch (e) {
    return (out: _err(e), keys: resolved, draws: idx);
  } on ArgumentError catch (e) {
    return (out: _err(e), keys: resolved, draws: idx);
  }
}

/// Script CSV minus the rows of [drop] serials (serials hold no commas).
String _dropRows(String csv, Set<String> drop) {
  final lines = csv.split('\n');
  return [
    lines.first,
    for (final l in lines.skip(1))
      if (l.isEmpty || !drop.contains(l.split(',')[1])) l,
  ].join('\n');
}

void _runSeed(String file, _Report r) {
  final cases =
      jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>;
  List<Map<String, dynamic>> cat(String n) =>
      (cases[n] as List).cast<Map<String, dynamic>>();

  for (final c in cat('normalize')) {
    Object? got;
    try {
      got = {'ikm_hex': _toHex(ykNormalizeMasterKey(_hex(c['raw_hex'])))};
    } on YkException catch (e) {
      got = _err(e);
    }
    r.check('normalize', got, c['expect'], c['raw_hex']);
  }

  for (final c in cat('derive')) {
    Object? got;
    try {
      final m = ykNormalizeMasterKey(_hex(c['raw_hex']));
      got = {
        'value': ykDerive(
            master: m,
            serial: c['serial'] as String,
            field: c['field'] as String,
            length: c['length'] as int?),
      };
    } on YkException catch (e) {
      got = _err(e);
    } on ArgumentError catch (e) {
      got = _err(e);
    }
    r.check('derive', got, c['expect'],
        {'serial': c['serial'], 'field': c['field'], 'length': c['length']});
  }

  for (final c in cat('sampler')) {
    Object? got;
    try {
      final s = ykSampleOkm(
          _hex(c['okm_hex']), c['alphabet'] as String, c['length'] as int);
      got = {
        'value': s.value,
        'bytes_consumed': s.bytesConsumed,
        'bytes_rejected': s.bytesRejected,
      };
    } on YkException catch (e) {
      got = _err(e);
    }
    r.check('sampler', got, c['expect'],
        {'field': c['field'], 'length': c['length']});
  }

  for (final c in cat('otp')) {
    final input = c['input'] as String;
    Object? direct;
    try {
      direct = {'value': ykOtpFromSerial(input)};
    } on YkException catch (e) {
      direct = _err(e);
    }
    r.check('otp', direct, c['expect_direct'], input.codeUnits);
    Object? script;
    try {
      final k = ykResolveKey(
          serial: input,
          phases: {YkPhase.otp},
          mode: YkMode.random,
          otpFromSerial: true,
          nextIntForTest: (_) => 0);
      script = {
        'value': k.values['45'],
        'stripped': k.serial,
        if (k.values['46'] != k.values['45']) 'slot2_differs': true,
      };
    } on YkException catch (e) {
      script = _err(e);
    }
    r.check('otp_script', script, c['expect_script'], input.codeUnits);
  }

  for (final c in cat('main')) {
    final keys = [
      for (final k in (c['keys'] as List).cast<Map<String, dynamic>>())
        (
          serial: k['serial'] as String,
          manual: (k['manual'] as Map).cast<String, String>(),
        ),
    ];
    final log = [
      for (final e in c['random_log'] as List) (e as List).cast<int>(),
    ];
    final res = _runMain(
      mode: c['mode'] as String,
      raw: _hex(c['raw_hex']),
      phases: _phases((c['phases'] as List).cast<String>()),
      otpFromSerial: c['otp_from_serial'] as bool,
      keys: keys,
      log: log,
    );
    final py = c['py'] as Map<String, dynamic>;
    var want = c['expect'] as Map<String, dynamic>;
    final stripped = [
      for (final k in keys) pythonStrip(k.serial),
    ].where((s) => s.isNotEmpty).toList();
    final formula = stripped.where(_formula).toSet();
    final anyUnsafe = stripped.any(_unsafe);
    if (c['note'] != null) r.diverge('csv-unsafe serial (verifier note)');
    if (formula.isNotEmpty &&
        (py.containsKey('csv') || py['error'] == 'VALUE_INVALID')) {
      // New documented divergence: formula-leading serials are refused.
      want = {'error': YkException.serialInvalid};
      r.diverge('formula serial');
      // The other keys must still export byte-identically.
      if (py.containsKey('csv') && !anyUnsafe && res.keys != null) {
        final rest =
            res.keys!.where((k) => !formula.contains(k.serial)).toList();
        if (rest.isNotEmpty) {
          r.diverge('formula serial: rest compared');
          r.check('main_formula_rest', {'csv': ykBitwardenCsv(rest)},
              {'csv': _dropRows(py['csv'] as String, formula)}, c['keys']);
        }
      }
    }
    r.check('main', res.out, want, {'keys': c['keys'], 'mode': c['mode']});
    r.check('main_draws', res.draws, log.length, c['keys']);
  }

  for (final c in cat('check')) {
    final p = ykValidateValue(c['field'] as String, c['value'] as String);
    r.check(
        'check',
        {
          'len': p.isEmpty ? c['len'] : p.first.length,
          'length_ok': !p.any((x) => x.kind == YkValueProblemKind.length),
          'chars_ok': !p.any((x) => x.kind == YkValueProblemKind.alphabet),
        },
        {
          'len': c['len'],
          'length_ok': c['length_ok'],
          'chars_ok': c['chars_ok'],
        },
        c['value']);
  }

  for (final c in cat('sha')) {
    Object? got;
    try {
      got = {'value': ykSha256Prefix6(c['value'] as String)};
    } on ArgumentError catch (e) {
      got = _err(e);
    }
    r.check('sha', got, c['expect'], (c['value'] as String).codeUnits);
  }
}

void main() {
  for (final seed in [0, 1, 2, 3, 4, 5]) {
    test('seed $seed', () {
      final r = _Report();
      _runSeed('$_dir/cases_seed$seed.json', r);
      File('$_dir/mismatches_fixer_seed$seed.json').writeAsStringSync(
          const JsonEncoder.withIndent(' ').convert(r.toJson()));
      print('seed $seed counts=${r.counts} '
          'mismatches=${r.mismatchCounts} divergences=${r.divergences}');
      expect(r.total, 0);
    });
  }

  test('real CLI runs (Ruby YAML)', () {
    final runs = (jsonDecode(File('$_dir/cli_cases.json').readAsStringSync())
            as List)
        .cast<Map<String, dynamic>>();
    final r = _Report();
    for (final run in runs) {
      final man = run['manifest'] as Map<String, dynamic>;
      final batch = man['batch'] as Map<String, dynamic>;
      final phasesMap = (man['phases'] as Map).cast<String, dynamic>();
      final keys = [
        for (final k in (man['keys'] as List).cast<Map<String, dynamic>>())
          (
            serial: '${k['serial'] ?? ''}',
            manual: {
              for (final e in ((k['secrets'] as Map?) ?? const {}).entries)
                '${e.key}': '${e.value}',
            },
          ),
      ];
      final res = _runMain(
        mode: '${batch['secrets']}'.toLowerCase(),
        raw: _hex(run['master_hex'] as String),
        phases: _phases(['openpgp', 'fido2', 'oath', 'otp']
            .where((p) => phasesMap[p] == true)),
        otpFromSerial:
            (man['options'] as Map)['otp_access_from_serial'] == true,
        keys: keys,
      );
      final scriptCsv = run['csv_b64'] == null
          ? null
          : utf8.decode(base64.decode(run['csv_b64'] as String));
      Map<String, Object?> want = scriptCsv == null
          ? {'error': YkException.valueInvalid}
          : {'csv': scriptCsv};
      final formula = {
        for (final k in keys)
          if (_formula(pythonStrip(k.serial))) pythonStrip(k.serial),
      };
      if (formula.isNotEmpty) {
        want = {'error': YkException.serialInvalid};
        r.diverge('formula serial (${run['name']})');
        if (scriptCsv != null && res.keys != null) {
          final rest =
              res.keys!.where((k) => !formula.contains(k.serial)).toList();
          r.check('cli_formula_rest', {'csv': ykBitwardenCsv(rest)},
              {'csv': _dropRows(scriptCsv, formula)}, run['name']);
        }
      }
      print('${run['name']}: rc=${run['rc']} dart=${res.out.keys.first}'
          '${res.out['error'] ?? ''}');
      r.check('cli', res.out, want, run['name']);
    }
    File('$_dir/mismatches_fixer_cli.json').writeAsStringSync(
        const JsonEncoder.withIndent(' ').convert(r.toJson()));
    print('cli counts=${r.counts} mismatches=${r.mismatchCounts} '
        'divergences=${r.divergences}');
    expect(r.total, 0);
  });
}
