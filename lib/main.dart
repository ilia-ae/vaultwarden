import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'demo_fixtures.dart';
import 'services/settings_service.dart';

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  FlutterNativeSplash.preserve(widgetsBinding: binding);
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
