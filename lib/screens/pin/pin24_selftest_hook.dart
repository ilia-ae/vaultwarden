import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../pin_tools/pin24_selftest.dart';
import 'pin24_engine.dart';

/// Outcome of the "Check engine" button: how many official Ledger vectors
/// the Dart engine reproduced. Carries no seed words and no passwords.
class Pin24EngineCheckResult {
  const Pin24EngineCheckResult({required this.passed, required this.total});

  final int passed;
  final int total;

  bool get ok => total > 0 && passed == total;
}

/// The vectors "Check engine" replays: the official ones. Widget tests
/// override it with a broken list to see the failure message.
final pin24SelfTestVectorsProvider = Provider<List<Pin24SelfTestVector>>(
  (_) => kPin24OfficialVectors,
);

/// Runs the PIN 24 engine self-test ([runPin24SelfTest]: the official
/// LedgerHQ vectors on the public Speculos seed, or [vectors]) through
/// [runner], i.e. off the UI isolate. Never uses anything the user typed.
Future<Pin24EngineCheckResult> pin24EngineCheck(
  PinComputeRunner runner, {
  List<Pin24SelfTestVector> vectors = kPin24OfficialVectors,
}) async {
  final result = await runner(() => runPin24SelfTest(vectors: vectors));
  return Pin24EngineCheckResult(
    passed: result.passedCount,
    total: result.total,
  );
}
