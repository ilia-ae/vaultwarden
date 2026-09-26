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

/// Runs the PIN 24 engine self-test ([runPin24SelfTest]: the official
/// LedgerHQ vectors on the public Speculos seed) through [runner], i.e. off
/// the UI isolate. Never uses anything the user typed.
Future<Pin24EngineCheckResult> pin24EngineCheck(
  PinComputeRunner runner,
) async {
  final result = await runner(_selfTest);
  return Pin24EngineCheckResult(
    passed: result.passedCount,
    total: result.total,
  );
}

/// Top-level so the isolate closure captures nothing.
Pin24SelfTestResult _selfTest() => runPin24SelfTest();
