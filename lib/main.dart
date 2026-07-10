import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'app.dart';
import 'demo_fixtures.dart';
import 'firebase_options.dart';
import 'services/settings_service.dart';

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: binding);

  // Firebase backs the optional settings cloud sync. Initialise it
  // non-fatally: if it fails (e.g. offline, misconfigured, or a demo
  // build) the app still runs fully — only cloud sync is unavailable.
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    firebaseReady = true;
  } catch (e, st) {
    debugPrint('Firebase init failed (cloud sync disabled): $e\n$st');
  }

  final settings = await SettingsService.create();

  // Pre-warm Liquid Glass shaders (prevents a white flash on first glass paint).
  await LiquidGlassWidgets.initialize(enablePerformanceMonitor: false);

  runApp(
    LiquidGlassWidgets.wrap(
      // adaptiveQuality benchmarks the device and steps glass quality up/down,
      // so lower-end Android stays smooth while capable devices get premium.
      adaptiveQuality: true,
      child: ProviderScope(
        overrides: [
          settingsServiceProvider.overrideWithValue(settings),
          ...demoModeOverrides(),
        ],
        child: const App(),
      ),
    ),
  );
}
