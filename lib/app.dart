import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'demo_runtime.dart';
import 'l10n/app_localizations.dart';
import 'providers/session_provider.dart';
import 'widgets/unlock_shell.dart';
import 'screens/requests_screen.dart';
import 'screens/setup_screen.dart';
import 'services/settings_service.dart';
import 'services/settings_sync.dart';
import 'widgets/app_background.dart';

/// True once Firebase.initializeApp succeeded (set in main). Gates all cloud
/// sync — when false, FirebaseAuth/Firestore are never touched.
bool firebaseReady = false;

/// Floating, rounded, dark translucent SnackBar — same in light and dark so the
/// default Material 3 light bar never jars against the dark theme.
const _appSnackBarTheme = SnackBarThemeData(
  behavior: SnackBarBehavior.floating,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(14)),
  ),
  backgroundColor: Color(0xE61C1C22),
  contentTextStyle: TextStyle(color: Colors.white, fontSize: 14),
  elevation: 6,
  insetPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
);

/// Local settings store. Overridden in main() with a loaded instance; the
/// settings providers below read their initial values from it, and the App
/// widget writes changes back through it.
final settingsServiceProvider = Provider<SettingsService>(
  (_) => throw UnimplementedError('settingsServiceProvider must be overridden'),
);

/// Theme mode: system (default), light, or dark. Persisted locally.
final themeModeProvider = StateProvider<ThemeMode>(
  (ref) => ref.watch(settingsServiceProvider).themeMode,
);

/// The screenshot pipeline passes --dart-define=DEMO_BANNER=off so store
/// screenshots stay clean; every other demo build shows the ribbon.
const String _demoBannerFlag =
    String.fromEnvironment('DEMO_BANNER', defaultValue: 'on');

/// Compile-time DEMO_LOCALE override for screenshot capture builds.
///
/// On iOS the simulator's `-AppleLanguages` launch argument changes the
/// app's locale before MaterialApp resolves system default, so the
/// existing pipeline works without recompiling. On Android the
/// equivalent (`adb shell setprop persist.sys.locale` + reboot) doesn't
/// always propagate to Flutter's Window.locale reliably — Flutter caches
/// the value at engine init and post-reboot launches sometimes still
/// see the previous locale. To make per-locale screenshot batches
/// deterministic the capture pipeline rebuilds the APK with
/// `--dart-define=DEMO_LOCALE=<asc-code>` and we honor it here. Empty
/// string falls through to system default (production behavior).
const String _demoLocale =
    String.fromEnvironment('DEMO_LOCALE', defaultValue: '');

/// Parse an ASC-style locale code (en-US, ru, ar-SA, zh-Hans) into a
/// Flutter Locale. Distinguishes 4-letter script subtags (Hans/Hant)
/// from 2-letter region codes.
Locale? _parseAscLocale(String code) {
  if (code.isEmpty) return null;
  final parts = code.split('-');
  if (parts.length == 1) return Locale(parts[0]);
  final second = parts[1];
  if (second.length == 4) {
    return Locale.fromSubtags(languageCode: parts[0], scriptCode: second);
  }
  return Locale(parts[0], second);
}

/// App locale: null = system default; non-null overrides MaterialApp.locale.
/// DEMO_LOCALE (screenshot builds) wins; otherwise the persisted choice.
final localeProvider = StateProvider<Locale?>((ref) {
  if (_demoLocale.isNotEmpty) return _parseAscLocale(_demoLocale);
  return ref.watch(settingsServiceProvider).locale;
});

/// Lock timeout in seconds. 0 = immediate, -1 = never. Persisted locally.
final lockTimeoutProvider = StateProvider<int>(
  (ref) => ref.watch(settingsServiceProvider).lockTimeout ?? 0,
);

/// Poll interval in seconds for auth request refresh. Persisted locally.
final pollIntervalProvider = StateProvider<int>(
  (ref) => ref.watch(settingsServiceProvider).pollInterval ?? 15,
);

/// Whether the app is locked (biometric required before showing content).
/// Starts as true — the very first frame never shows sensitive data.
final isLockedProvider = StateProvider<bool>((_) => true);

class App extends ConsumerStatefulWidget {
  const App({super.key});

  @override
  ConsumerState<App> createState() => _AppState();
}

class _AppState extends ConsumerState<App> with WidgetsBindingObserver {
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Demo never locks: testers have no real key to unlock with.
    if (demoActive) return;
    final isLocked = ref.read(isLockedProvider);

    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      // Lock immediately when leaving foreground.
      // This runs BEFORE iOS captures the app snapshot, so
      // the snapshot (and the first resumed frame) show LockScreen.
      if (!isLocked) {
        final timeout = ref.read(lockTimeoutProvider);
        if (timeout != -1) {
          _pausedAt ??= DateTime.now();
          ref.read(isLockedProvider.notifier).state = true;
        }
      }
    } else if (state == AppLifecycleState.resumed) {
      final timeout = ref.read(lockTimeoutProvider);
      if (timeout == -1) return; // never-lock mode

      if (_pausedAt != null) {
        final elapsed = DateTime.now().difference(_pausedAt!).inSeconds;
        _pausedAt = null;

        if (elapsed < timeout) {
          // Timeout not reached — unlock without biometric.
          // The key is still in memory; just flip the flag.
          ref.read(isLockedProvider.notifier).state = false;
        } else {
          // Timeout exceeded — clear key, LockScreen will ask for biometric.
          ref.read(sessionProvider.notifier).lock();
        }
      }
      // If _pausedAt == null (e.g. biometric dialog triggered pause/resume),
      // do nothing — LockScreen handles its own flow.
    }
  }

  @override
  Widget build(BuildContext context) {
    // Persist settings changes locally. ref.listen fires only on change
    // (not for the loaded initial value), so this never clobbers on startup.
    final settings = ref.read(settingsServiceProvider);
    ref.listen<ThemeMode>(
        themeModeProvider, (_, next) => settings.setThemeMode(next));
    ref.listen<Locale?>(localeProvider, (_, next) {
      if (_demoLocale.isEmpty) settings.setLocale(next);
    });
    ref.listen<int>(
        lockTimeoutProvider, (_, next) => settings.setLockTimeout(next));
    ref.listen<int>(
        pollIntervalProvider, (_, next) => settings.setPollInterval(next));

    // Activate two-way cloud sync (no-op until a user signs in).
    if (firebaseReady) {
      ref.watch(settingsSyncCoordinatorProvider);
    }

    final sessionAsync = ref.watch(sessionProvider);
    final themeMode = ref.watch(themeModeProvider);
    final locale = ref.watch(localeProvider);
    final isLocked = ref.watch(isLockedProvider);

    return MaterialApp(
      title: 'Vault Approver',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      builder: (context, child) {
        // Scene background under every screen (scaffolds are transparent).
        final content = AppBackground(child: child!);
        // Ribbon rebuilds live when a tester flips the runtime demo toggle.
        return ValueListenableBuilder<bool>(
          valueListenable: demoRuntime,
          builder: (context, runtimeDemo, _) {
            final showBanner =
                runtimeDemo || (isDemoMode && _demoBannerFlag != 'off');
            if (!showBanner) return content;
            return Banner(
              message: 'DEMO',
              location: BannerLocation.topEnd,
              color: Colors.deepOrange,
              child: content,
            );
          },
        );
      },
      themeMode: themeMode,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.light,
        // The AppBackground scene shows through every screen.
        scaffoldBackgroundColor: Colors.transparent,
        snackBarTheme: _appSnackBarTheme,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.transparent,
        snackBarTheme: _appSnackBarTheme,
      ),
      home: sessionAsync.when(
        data: (session) {
          FlutterNativeSplash.remove();
          if (session == null) return const SetupScreen();
          // Locked: a data-free skeleton sits under the frosted veil; the
          // real screen mounts under FULL blur on unlock, then the veil
          // evaporates (Face ID de-blur reveal).
          return UnlockShell(
            locked: isLocked,
            child:
                isLocked ? const LockSkeleton() : const RequestsScreen(),
          );
        },
        loading: () {
          FlutterNativeSplash.remove();
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/icon/vault_approver_1024.png',
                    width: 120,
                    height: 120,
                  ),
                  const SizedBox(height: 32),
                  const CircularProgressIndicator(),
                ],
              ),
            ),
          );
        },
        error: (_, __) {
          FlutterNativeSplash.remove();
          return const SetupScreen();
        },
      ),
    );
  }
}
