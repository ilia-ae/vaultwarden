import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'demo_fixtures.dart';
import 'l10n/app_localizations.dart';
import 'models/settings_snapshot.dart';
import 'models/user_session.dart';
import 'providers/service_providers.dart';
import 'providers/session_provider.dart';
import 'widgets/unlock_shell.dart';
import 'screens/requests_screen.dart';
import 'screens/setup_screen.dart';
import 'services/settings_service.dart';
import 'services/settings_sync.dart';
import 'utils/external_picker.dart';
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
/// A stored value outside [kLockTimeoutOptions] reads as 0 (lock at once).
final lockTimeoutProvider = StateProvider<int>(
  (ref) => sanitizeLockTimeout(ref.watch(settingsServiceProvider).lockTimeout),
);

/// Poll interval in seconds for auth request refresh. Persisted locally.
/// Clamped to ≥ 5 s so a corrupt value can never poll in a tight loop (R2).
final pollIntervalProvider = StateProvider<int>(
  (ref) =>
      sanitizePollInterval(ref.watch(settingsServiceProvider).pollInterval),
);

/// True only inside the runtime demo's own ProviderContainer (see [App]).
final runtimeDemoScopeProvider = Provider<bool>((_) => false);

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

  /// The app's navigator. `UnlockShell` only covers the home route, so every
  /// route above it (Settings sheet, dialogs) is closed here: when the app
  /// locks (R6, [_closeRoutesOnLock]) — otherwise it would stay visible and
  /// usable over the lock — and when the session ends
  /// ([_closeRoutesOnSignOut]).
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// App-level messenger: SnackBars that must survive a switch of the home
  /// screen (session ended → setup screen, entering the demo).
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  /// This App runs inside the runtime demo's container.
  late final bool _inDemoScope = ref.read(runtimeDemoScopeProvider);

  /// The runtime demo's container while the tester demo is on (root App
  /// only). The whole UI then runs in it: a child of the real container
  /// that overrides session, requests, history, lock and user key, so no
  /// demo state can reach the real session or the server, and vice versa
  /// (F7). Settings and services are shared with the parent.
  ProviderContainer? _demoContainer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_inDemoScope) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showDemoNotice());
    } else {
      demoRuntime.addListener(_onRuntimeDemoChanged);
      if (demoRuntime.value) _openDemoContainer();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (!_inDemoScope) demoRuntime.removeListener(_onRuntimeDemoChanged);
    final demo = _demoContainer;
    _demoContainer = null;
    if (demo != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => demo.dispose());
    }
    super.dispose();
  }

  void _openDemoContainer() {
    _demoContainer ??= ProviderContainer(
      parent: ProviderScope.containerOf(context, listen: false),
      overrides: runtimeDemoOverrides(),
    );
  }

  void _onRuntimeDemoChanged() {
    if (!mounted) return;
    if (demoRuntime.value) {
      if (_demoContainer != null) return;
      setState(_openDemoContainer);
      return;
    }
    final demo = _demoContainer;
    if (demo == null) return;
    setState(() => _demoContainer = null);
    // Leaving the demo: the real container starts from a clean slate
    // (nothing in storage is touched, R4). Dispose the demo container once
    // its widgets are gone.
    ref.read(sessionProvider.notifier).resetLiveState();
    WidgetsBinding.instance.addPostFrameCallback((_) => demo.dispose());
  }

  void _showDemoNotice() {
    final messenger = _messengerKey.currentState;
    final context = _messengerKey.currentContext;
    if (messenger == null || context == null) return;
    messenger.showSnackBar(SnackBar(
      content: Text(AppLocalizations.of(context)!.demoModeNotice),
      duration: const Duration(seconds: 3),
    ));
  }

  /// F11/A9: tell the user why they are back on the setup screen.
  void _showSessionEndNotice(SessionEndNotice notice) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final messenger = _messengerKey.currentState;
      final context = _messengerKey.currentContext;
      if (messenger == null || context == null) return;
      final l = AppLocalizations.of(context)!;
      messenger.showSnackBar(SnackBar(
        content: Text(switch (notice) {
          SessionEndNotice.sessionEnded => l.sessionEndedOnServer,
          SessionEndNotice.signedOutByServer => l.signedOutByServer,
        }),
        duration: const Duration(seconds: 8),
      ));
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Demo never locks: testers have no real key to unlock with.
    if (demoActive) return;
    final isLocked = ref.read(isLockedProvider);

    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      // A system file picker backgrounds the app (Android: another
      // activity). Locking now would pop the route waiting for the file.
      if (externalPickerActive) return;
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
      // Keychain changes held back while protected data was unavailable
      // (device locked) are written now (SecureStorageService write guard).
      unawaited(ref.read(secureStorageProvider).flushPending());
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

  /// Closes every route above home when the app locks (R6). Only for a real
  /// signed-in session: the setup screen's dialogs (2FA code) must survive a
  /// trip to the authenticator app, demo mode never locks, and a system file
  /// picker must find the route that asked for the file still there.
  void _closeRoutesOnLock() {
    if (demoActive || externalPickerActive) return;
    if (ref.read(sessionProvider).valueOrNull == null) return;
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
  }

  /// Logout or a server-ended session (F11, A9): home becomes the setup
  /// screen, so close whatever the old session left above it. Otherwise the
  /// Settings sheet stays open over the setup screen (its "Log out" would
  /// act on a disposed screen) and covers the "session ended" SnackBar.
  void _closeRoutesOnSignOut() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _navigatorKey.currentState?.popUntil((route) => route.isFirst);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Runtime tester demo: the whole app runs in the demo's own container.
    final demo = _demoContainer;
    if (demo != null) {
      return UncontrolledProviderScope(container: demo, child: const App());
    }

    ref.listen<bool>(isLockedProvider, (previous, locked) {
      if (locked && previous == false) _closeRoutesOnLock();
    });
    ref.listen<SessionEndNotice?>(sessionEndNoticeProvider, (_, notice) {
      if (notice != null) _showSessionEndNotice(notice);
    });
    ref.listen<AsyncValue<UserSession?>>(sessionProvider, (previous, next) {
      if (previous?.valueOrNull != null &&
          next is AsyncData<UserSession?> &&
          next.value == null) {
        // Back to the initial locked state, so a stale "unlocked" never
        // carries over to the next session.
        _pausedAt = null;
        ref.read(isLockedProvider.notifier).state = true;
        _closeRoutesOnSignOut();
      }
    });

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
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
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
              message: AppLocalizations.of(context)!.demoRibbon,
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
            child: isLocked ? const LockSkeleton() : const RequestsScreen(),
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
        // R4: a keychain read error is not "logged out" — offer a retry
        // instead of the setup screen (where a demo round-trip or a new
        // login would replace the real keys).
        error: (_, __) {
          FlutterNativeSplash.remove();
          return StorageErrorScreen(
            onRetry: () => ref.invalidate(sessionProvider),
            onLogout: () => ref.read(sessionProvider.notifier).logout(),
          );
        },
      ),
    );
  }
}

/// Shown when the session could not be read from the keychain (device
/// locked, keystore unavailable…). Retry re-reads it; "Log out" (confirmed)
/// is the way out when the keychain stays unreadable.
class StorageErrorScreen extends StatelessWidget {
  const StorageErrorScreen({
    super.key,
    required this.onRetry,
    required this.onLogout,
  });

  final VoidCallback onRetry;
  final Future<void> Function() onLogout;

  Future<void> _confirmLogout(BuildContext context) async {
    final l = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.logoutTitle),
        content: Text(l.logoutConfirmation),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.logout),
          ),
        ],
      ),
    );
    if (confirmed == true) await onLogout();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.lock_reset_outlined,
                  size: 64,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(height: 16),
                Text(
                  l.storageErrorTitle,
                  style: theme.textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  l.storageErrorMessage,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                Semantics(
                  identifier: 'btn_storage_retry',
                  child: FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: Text(l.retry),
                  ),
                ),
                const SizedBox(height: 8),
                Semantics(
                  identifier: 'btn_storage_logout',
                  child: TextButton(
                    onPressed: () => _confirmLogout(context),
                    child: Text(l.logout),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
