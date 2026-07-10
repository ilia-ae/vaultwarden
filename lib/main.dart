import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  } catch (e, st) {
    debugPrint('Firebase init failed (cloud sync disabled): $e\n$st');
  }

  final settings = await SettingsService.create();
  runApp(
    ProviderScope(
      overrides: [
        settingsServiceProvider.overrideWithValue(settings),
        ...demoModeOverrides(),
      ],
      child: const App(),
    ),
  );
}
