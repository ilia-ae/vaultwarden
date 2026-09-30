import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'demo_fixtures.dart';
import 'firebase_options.dart';
import 'providers/service_providers.dart';
import 'services/pin_shift_vector_store.dart';
import 'services/secure_storage_service.dart';
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

  // A reinstall must not bring back the previous installation's session,
  // keys and certificates (iOS keeps keychain items across uninstall).
  if (!isDemoMode) {
    try {
      await SecureStorageService()
          .wipeIfReinstalled(await SharedPreferences.getInstance());
    } catch (e) {
      debugPrint('Reinstall check failed: $e');
    }
  }

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
          // PIN Shift's saved vector lives in the app's keychain store (the
          // same guarded write path as the session).
          pinShiftVectorStoreProvider
              .overrideWith((ref) => ref.watch(secureStorageProvider)),
          ...demoModeOverrides(),
        ],
        child: const App(),
      ),
    ),
  );
}
