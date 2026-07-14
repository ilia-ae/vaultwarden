import 'package:flutter/foundation.dart';

/// Demo-mode flags, kept in a leaf library (no provider imports) so any file —
/// including app.dart — can read them without an import cycle.

/// Compile-time demo mode for App Store screenshot capture
/// (`--dart-define=DEMO_MODE=<main|lock|setup|totp|off>`).
const String demoMode =
    String.fromEnvironment('DEMO_MODE', defaultValue: 'off');

bool get isDemoMode => demoMode != 'off';

/// Runtime demo toggle for testers: tap the build version on the setup screen
/// five times. Independent of the compile-time screenshot flag, so a normal
/// production build can drop into demo data on demand. A [ValueNotifier] so the
/// DEMO ribbon rebuilds the moment it flips.
final ValueNotifier<bool> demoRuntime = ValueNotifier<bool>(false);

/// True when the app should serve demo fixtures instead of real data — either
/// the compile-time screenshot flag or the runtime tester toggle.
bool get demoActive => isDemoMode || demoRuntime.value;
