import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:vault_approver/pin_tools/ledger_pin24.dart';
import 'package:vault_approver/pin_tools/pin24_selftest.dart';

const _speculosWords = [
  'glory', 'promote', 'mansion', 'idle', 'axis', 'finger', 'extra', //
  'february', 'uncover', 'one', 'trip', 'resource', 'lawn', 'turtle', //
  'enact', 'monster', 'seven', 'myth', 'punch', 'hobby', 'comfort', //
  'wild', 'raise', 'skin',
];

void main() {
  test('the table is exactly the fixture\'s 10 official vectors', () {
    final doc = jsonDecode(
      File('test/pin_tools/fixtures/pin24_vectors.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final official = [
      for (final v in (doc['vectors'] as List).cast<Map<String, dynamic>>())
        if ((v['tags'] as List).contains('official')) v,
    ];
    expect(official, hasLength(10));
    expect(kPin24OfficialVectors, hasLength(10));
    for (var i = 0; i < 10; i++) {
      final v = official[i];
      final t = kPin24OfficialVectors[i];
      expect(v['mnemonic'], _speculosWords.join(' '));
      expect(t.setMask, (v['options'] as Map)['set_mask']);
      expect(t.nickname, v['nickname']);
      expect(t.expected, v['expected_output']);
    }
  });

  test('the engine passes all official vectors', () {
    final r = runPin24SelfTest();
    expect(r.passed, isTrue);
    expect(r.total, 10);
    expect(r.passedCount, 10);
    expect(r.failedCount, 0);
    expect(r.cases.map((c) => c.number), List.generate(10, (i) => i + 1));
    expect(r.cases.every((c) => c.passed && c.errorCode == null), isTrue);
    expect(r.cases.first.label, '#1 0x01 gmail');
    expect(r.cases.last.label, '#10 0xFF aSeedOfLengthEqual20');
    expect(r.toString(), startsWith('Pin24SelfTestResult(10/10 passed, '));
    expect(r.elapsed, greaterThan(Duration.zero));
  });

  test('runs in an isolate (the way the UI calls it)', () async {
    final r = await Isolate.run(runPin24SelfTest);
    expect(r.passed, isTrue);
  });

  test('failures are reported per vector with their error code', () {
    final ok = kPin24OfficialVectors[2];
    final r = runPin24SelfTest(vectors: [
      ok,
      Pin24SelfTestVector(ok.setMask, ok.nickname, 'not-the-output'),
      const Pin24SelfTestVector(0, 'gmail', 'x'),
      const Pin24SelfTestVector(0x01, '', 'x'),
      Pin24SelfTestVector(0x01, 'a${String.fromCharCode(0xD800)}', 'x'),
    ]);
    expect(r.passed, isFalse);
    expect(r.passedCount, 1);
    expect(r.failedCount, 4);
    expect(r.cases.map((c) => c.passed), [true, false, false, false, false]);
    expect(r.cases.map((c) => c.errorCode), [
      null,
      null,
      Pin24Exception.setMaskRange,
      Pin24Exception.nicknameEmpty,
      Pin24Exception.nicknameNotUtf8,
    ]);
    expect(r.cases[2].toString(), '#3 0x00 gmail: FAIL (SET_MASK_RANGE)');
    expect(runPin24SelfTest(vectors: const []).passed, isFalse);
  });

  test('results expose neither seed words nor passwords', () {
    final r = runPin24SelfTest();
    final text = [
      r.toString(),
      for (final c in r.cases) ...[c.toString(), c.label],
    ].join('\n');
    for (final w in _speculosWords) {
      expect(text, isNot(contains(w)), reason: w);
    }
    for (final v in kPin24OfficialVectors) {
      expect(text, isNot(contains(v.expected)));
    }
  });
}
