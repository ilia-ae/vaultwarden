import 'pin24_engine.dart';

/// Outcome of the "Check engine" button: how many official Ledger vectors
/// the Dart engine reproduced.
class Pin24EngineCheckResult {
  const Pin24EngineCheckResult({required this.passed, required this.total});

  final int passed;
  final int total;

  bool get ok => total > 0 && passed == total;
}

/// Runs the PIN 24 engine self-test off the UI isolate, or returns `null`
/// when this build has no self-test.
///
/// TODO(pin24-selftest): `lib/pin_tools/pin24_selftest.dart` (plan item B7:
/// the official Speculos vectors as consts plus `runPin24SelfTest()`) has not
/// landed yet. When it does, replace the body with
/// `runner(() => runPin24SelfTest())` mapped to [Pin24EngineCheckResult].
/// Until then the button says the check is unavailable in this build.
Future<Pin24EngineCheckResult?> pin24EngineCheck(
  PinComputeRunner runner,
) async =>
    null;
