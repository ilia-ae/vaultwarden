/// "Check engine": replays the official LedgerHQ/app-passwords vectors
/// against this device's PIN 24 engine ([bip39ToSeed] + [derivePassword]).
///
/// The vectors are upstream `tests/functional/tests_vectors.py`, as pinned
/// in personal-crypto-tools `tests/test_pin24.py`: the passwords the real
/// app types on Speculos for the public Speculos test seed. A pass proves
/// the whole chain (BIP39 PBKDF2, BIP32, CTR_DRBG, sampling, shuffle) matches
/// the device on this platform.
///
/// The seed phrase is a public test mnemonic, never a user secret, but the
/// results still carry no seed words and no derived passwords: only vector
/// numbers, masks, nicknames, pass/fail and error codes, so they are safe to
/// show and log.
///
/// Pure Dart; costs one PBKDF2 (about 0.1 s). Call it through
/// `Isolate.run(runPin24SelfTest)` from the UI.
library;

import 'dart:typed_data';

import 'ledger_pin24.dart';

/// One official vector: the password the app types for [nickname] with the
/// charset mask [setMask] (default size 20, default minimums).
class Pin24SelfTestVector {
  const Pin24SelfTestVector(this.setMask, this.nickname, this.expected);

  final int setMask;
  final String nickname;
  final String expected;
}

/// Speculos' default seed (public; used by every Ledger app's functional
/// tests).
const String _speculosSeedPhrase =
    'glory promote mansion idle axis finger extra february uncover one trip '
    'resource lawn turtle enact monster seven myth punch hobby comfort wild '
    'raise skin';

/// The 10 official vectors, in upstream order.
const List<Pin24SelfTestVector> kPin24OfficialVectors = [
  Pin24SelfTestVector(0x01, 'gmail', 'HMYDQUIOVKPCKJIHQJEN'),
  Pin24SelfTestVector(0x03, 'gmail', 'KqIJcPjhENivHvOdmuKQ'),
  Pin24SelfTestVector(0x07, 'gmail', 'xNX8IQO4vP0ucO41J6JW'),
  Pin24SelfTestVector(0x0F, 'gmail', 'w14JrbA9HNvWU1ON5MGP'),
  Pin24SelfTestVector(0x1F, 'gmail', 'vy4Joa86FKvVS1ON4KEP'),
  Pin24SelfTestVector(0x3F, 'gmail', 'kD83CP1UZO vQvJIuNx4'),
  Pin24SelfTestVector(0x7F, 'gmail', '?u8htP1|DO v7vJzYNb4'),
  Pin24SelfTestVector(0xFF, 'gmail', '*m8ZlP1|}O vzvJrQNT4'),
  Pin24SelfTestVector(0xFF, 'aseedoflengthequal20', '29!uO;UPx UT8Hkmi- 5'),
  Pin24SelfTestVector(0xFF, 'aSeedOfLengthEqual20', r' $4,P.usI*C\k1fv2;M;'),
];

/// Outcome of one vector. Holds no seed words and no passwords.
class Pin24SelfTestCase {
  const Pin24SelfTestCase({
    required this.number,
    required this.setMask,
    required this.nickname,
    required this.passed,
    this.errorCode,
  });

  /// 1-based position in the vector table.
  final int number;
  final int setMask;
  final String nickname;
  final bool passed;

  /// Why it failed: a [Pin24Exception.code], or `UNEXPECTED_ERROR` for any
  /// other exception. Null when it passed or the output simply differed.
  final String? errorCode;

  /// `#1 0x01 gmail`: what the UI lists next to the pass/fail mark.
  String get label =>
      '#$number 0x${setMask.toRadixString(16).padLeft(2, '0').toUpperCase()} '
      '$nickname';

  @override
  String toString() => '$label: ${passed ? 'pass' : 'FAIL'}'
      '${errorCode == null ? '' : ' ($errorCode)'}';
}

/// Result of [runPin24SelfTest].
class Pin24SelfTestResult {
  const Pin24SelfTestResult(this.cases, this.elapsed);

  /// One entry per vector, in table order.
  final List<Pin24SelfTestCase> cases;

  /// Wall time of the whole run (dominated by one PBKDF2).
  final Duration elapsed;

  int get total => cases.length;
  int get passedCount => cases.where((c) => c.passed).length;
  int get failedCount => total - passedCount;

  /// Every vector reproduced exactly (and there was at least one).
  bool get passed => cases.isNotEmpty && failedCount == 0;

  @override
  String toString() => 'Pin24SelfTestResult($passedCount/$total passed, '
      '${elapsed.inMilliseconds} ms)';
}

/// Runs [vectors] (default: the 10 official ones) and reports pass/fail per
/// vector. Never throws: an engine error fails the vectors it affects, with
/// its code. The BIP39 seed is derived once from the Speculos phrase and
/// zeroed afterwards.
Pin24SelfTestResult runPin24SelfTest({
  List<Pin24SelfTestVector> vectors = kPin24OfficialVectors,
}) {
  final sw = Stopwatch()..start();
  final cases = <Pin24SelfTestCase>[];
  Pin24SelfTestCase outcome(int i, bool passed, [String? code]) =>
      Pin24SelfTestCase(
        number: i + 1,
        setMask: vectors[i].setMask,
        nickname: vectors[i].nickname,
        passed: passed,
        errorCode: code,
      );

  String codeOf(Object e) => e is Pin24Exception ? e.code : 'UNEXPECTED_ERROR';

  final Uint8List seed;
  try {
    seed = bip39ToSeed(_speculosSeedPhrase);
  } catch (e) {
    for (var i = 0; i < vectors.length; i++) {
      cases.add(outcome(i, false, codeOf(e)));
    }
    return Pin24SelfTestResult(List.unmodifiable(cases), sw.elapsed);
  }
  try {
    for (var i = 0; i < vectors.length; i++) {
      final v = vectors[i];
      try {
        final got = derivePassword(
          bip39Seed: seed,
          nickname: v.nickname,
          setMask: v.setMask,
        );
        cases.add(outcome(i, got == v.expected));
      } catch (e) {
        cases.add(outcome(i, false, codeOf(e)));
      }
    }
  } finally {
    seed.fillRange(0, seed.length, 0);
  }
  return Pin24SelfTestResult(List.unmodifiable(cases), sw.elapsed);
}
