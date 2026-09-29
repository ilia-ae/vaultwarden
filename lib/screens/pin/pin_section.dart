import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../services/privacy_service.dart';
import '../../utils/external_picker.dart';
import '../../widgets/keyboard_dismiss.dart';
import '../../widgets/option_pills.dart';
import 'legacy_mask_view.dart';
import 'pin24_view.dart';
import 'pin_prefs.dart';
import 'pin_session.dart';
import 'pin_shift_view.dart';
import 'pin_widgets.dart';
import 'yubikey_view.dart';

/// Why the PIN content is covered right now.
enum PinVeil {
  none,

  /// The app is not active (app switcher, Control Center, a system alert):
  /// covered, but nothing is wiped, so a paste alert does not lose input.
  inactive,

  /// iOS reports screen recording, AirPlay or mirroring: covered and the
  /// keyboard is dismissed until capture stops.
  captured,
}

/// Whether any part of the PIN tab is on screen, set by the screen that
/// hosts the tab (`RequestsScreen`, from its tab controller). When it turns
/// `false` the mounted [PinSection] unfocuses and wipes everything, so a
/// focused field (which keeps its page alive offscreen) cannot keep secrets
/// around once the user has left the tab.
final ValueNotifier<bool> pinTabVisible = ValueNotifier<bool>(false);

/// The PIN tab: tool picker plus the selected tool.
///
/// Owns the section's safety rules, independent of the app lock timeout
/// (which may be "never") and of demo mode:
/// * `hidden`/`paused` wipes everything (unless a system file picker is
///   open, see [externalPickerActive]); `inactive` only covers the content;
/// * 120 s without interaction wipes everything ([PinSession.touch]);
/// * leaving the tab ([pinTabVisible] turns `false`) unfocuses and wipes
///   everything; the section is never kept alive offscreen;
/// * iOS screen capture covers the content; a screenshot shows a warning with
///   a Wipe action;
/// * a user-initiated wipe (🧹, 🚨, the screenshot Wipe, leaving the tab)
///   also clears the clipboard: our own copy if it is still there, and a
///   pasted secret the user was reminded about.
///
/// FLAG_SECURE (Android) is switched by `RequestsScreen` from the tab index;
/// the section holds it as well until it is disposed, so it stays on while
/// the page is still alive after the tab changed.
class PinSection extends ConsumerStatefulWidget {
  const PinSection({super.key});

  @override
  ConsumerState<PinSection> createState() => _PinSectionState();
}

class _PinSectionState extends ConsumerState<PinSection>
    with WidgetsBindingObserver {
  late final ProviderSubscription<PinSession> _sessionSub;
  late final PinSession _session;
  late final PrivacyService _privacy;
  StreamSubscription<PrivacyEvent>? _events;

  bool _inactive = false;
  bool _captured = false;
  bool? _showLegacy;
  bool _screenshotsAllowedBuild = false;
  bool _tabVisible = pinTabVisible.value;
  ScaffoldMessengerState? _messenger;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sessionSub = ref.listenManual(pinSessionProvider, (_, __) {});
    _session = _sessionSub.read();
    _session.wipes.addListener(_onWipe);
    _session.onUserCleanup = _userCleanup;
    _privacy = ref.read(privacyServiceProvider);
    _events = _privacy.events.listen(_onPrivacyEvent);
    pinTabVisible.addListener(_onTabVisibility);
    // Nested with RequestsScreen's own hold: FLAG_SECURE stays on until this
    // section is gone, even if the tab index changed first.
    unawaited(_privacy.setSecureScreen(true));
    _session.touch();
    unawaited(_checkScreenshotsAllowedBuild());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _messenger = ScaffoldMessenger.maybeOf(context);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    pinTabVisible.removeListener(_onTabVisibility);
    unawaited(_events?.cancel());
    _session.wipes.removeListener(_onWipe);
    if (_session.onUserCleanup == _userCleanup) _session.onUserCleanup = null;
    _sessionSub.close();
    unawaited(_privacy.setSecureScreen(false));
    super.dispose();
  }

  /// The tab was left: nothing of the section may stay alive or focused.
  void _onTabVisibility() {
    final visible = pinTabVisible.value;
    final left = _tabVisible && !visible;
    _tabVisible = visible;
    if (!left || !mounted) return;
    final hadUnsaved = _session.hasUnsavedValues;
    _session.wipe(reason: PinWipeReason.left);
    if (hadUnsaved) {
      final l = AppLocalizations.of(context)!;
      _messenger
        ?..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(l.pinYkRandomErasedLeft)));
    }
  }

  /// Clipboard cleanup of a user-initiated wipe or Clear: our own copy if it
  /// is still on the clipboard, and a secret the user pasted.
  Future<void> _userCleanup() async {
    final pasted = _session.clipboardHoldsPaste.value;
    await _privacy.clearClipboardIfOurs();
    if (pasted) {
      await _privacy.clearClipboard();
      if (mounted) _session.clipboardHoldsPaste.value = false;
    }
  }

  /// Unfocuses the field that has focus inside this section (its keyboard
  /// and its keep-alive go with it).
  void _unfocusInside() {
    final focus = FocusManager.instance.primaryFocus;
    final focusContext = focus?.context;
    if (focus == null || focusContext == null || !mounted) return;
    var inside = false;
    focusContext.visitAncestorElements((e) {
      if (e == context) {
        inside = true;
        return false;
      }
      return true;
    });
    if (inside) focus.unfocus();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_inactive) setState(() => _inactive = false);
      case AppLifecycleState.inactive:
        if (!_inactive) setState(() => _inactive = true);
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        if (!_inactive) setState(() => _inactive = true);
        // A system file picker backgrounds the app on Android; its caller
        // must get its answer, so nothing is wiped while one is open.
        if (!externalPickerActive) {
          _session.wipe(reason: PinWipeReason.background);
        }
    }
  }

  /// Test builds made with `-Pallow-screenshots=true` never set FLAG_SECURE;
  /// say so, so nobody mistakes such a build for a protected one.
  Future<void> _checkScreenshotsAllowedBuild() async {
    final allowed = await _privacy.isScreenshotsAllowedBuild();
    if (mounted && allowed) setState(() => _screenshotsAllowedBuild = true);
  }

  void _onPrivacyEvent(PrivacyEvent event) {
    if (!mounted) return;
    switch (event) {
      case CaptureChanged(:final captured):
        if (captured) FocusManager.instance.primaryFocus?.unfocus();
        if (captured != _captured) setState(() => _captured = captured);
      case ScreenshotTaken():
        final l = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            duration: const Duration(seconds: 10),
            content: Text(l.pinScreenshotWarning),
            action: SnackBarAction(
              label: l.pinWipeAction,
              onPressed: () => _session.wipe(reason: PinWipeReason.screenshot),
            ),
          ));
    }
  }

  void _onWipe() {
    final event = _session.wipes.value;
    if (event == null || !mounted) return;
    // Wiped fields must not keep focus (nor the keyboard, nor an undo client).
    _unfocusInside();
    final pasted = _session.clipboardHoldsPaste.value;
    switch (event.reason) {
      case PinWipeReason.user:
      case PinWipeReason.screenshot:
      case PinWipeReason.left:
        // The user asked for it: take our copy back, and the pasted secret.
        unawaited(_userCleanup());
      case PinWipeReason.inactivity:
        // Our own copy only; a pasted secret keeps its reminder.
        unawaited(_privacy.clearClipboardIfOurs());
      case PinWipeReason.background:
        // The user may be pasting the result into another app right now;
        // the reminder about a pasted secret is back on return.
        break;
    }
    if (event.reason == PinWipeReason.left) return;
    final l = AppLocalizations.of(context)!;
    final String? message = switch (event.reason) {
      PinWipeReason.user =>
        event.scope == PinWipeScope.seed ? l.pinWipedSeed : l.pinWipedAll,
      PinWipeReason.screenshot => l.pinWipedAll,
      PinWipeReason.background =>
        event.hadContent ? l.pinWipedBackground : null,
      PinWipeReason.inactivity =>
        event.hadContent ? l.pinWipedInactivity : null,
      PinWipeReason.left => null,
    };
    if (message == null) return;
    final withClipboard = pasted &&
            (event.reason == PinWipeReason.user ||
                event.reason == PinWipeReason.screenshot)
        ? l.pinWipedClipboardToo(message)
        : message;
    _messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(withClipboard)));
  }

  Future<void> _selectTool(PinTool tool) async {
    _session.touch();
    final current = ref.read(pinToolProvider);
    if (tool == current) return;
    if (_session.hasUnsavedValues) {
      final l = AppLocalizations.of(context)!;
      final ok = await confirmPinAction(
        context: context,
        session: _session,
        tone: PinDialogTone.destructive,
        title: l.pinYkRandomLoseTitle,
        body: l.pinYkRandomLoseBody,
        confirmLabel: l.pinYkRandomLoseConfirm,
        confirmId: 'pin_tool_switch_confirm',
        cancelId: 'pin_tool_switch_cancel',
      );
      if (!ok || !mounted) return;
    }
    _session.returnTo = null;
    ref.read(pinToolProvider.notifier).state = tool;
  }

  void _setShowLegacy(PinPrefs prefs, bool show) {
    _session.touch();
    HapticFeedback.selectionClick();
    unawaited(prefs.setShowLegacyTools(show));
    setState(() => _showLegacy = show);
    if (!show && ref.read(pinToolProvider) == PinTool.legacyMask) {
      ref.read(pinToolProvider.notifier).state = PinTool.pin24;
    }
  }

  PinVeil get _veil => _captured
      ? PinVeil.captured
      : (_inactive ? PinVeil.inactive : PinVeil.none);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final prefsAsync = ref.watch(pinPrefsProvider);
    return prefsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(l.pinUnavailable, textAlign: TextAlign.center),
        ),
      ),
      data: (prefs) => _content(context, l, prefs),
    );
  }

  Widget _content(BuildContext context, AppLocalizations l, PinPrefs prefs) {
    final showLegacy = _showLegacy ??= prefs.showLegacyTools;
    final selected = ref.watch(pinToolProvider);
    final tool = selected == PinTool.legacyMask && !showLegacy
        ? PinTool.pin24
        : selected;
    final veil = _veil;
    final padding = MediaQuery.paddingOf(context);

    final tools = [
      (value: PinTool.pin24, label: l.pinToolPin24),
      (value: PinTool.pinShift, label: l.pinToolShift),
      (value: PinTool.yubikey, label: l.pinToolYubikey),
      if (showLegacy) (value: PinTool.legacyMask, label: l.pinToolLegacy),
    ];

    // iOS number pads have no return key: a tap outside the fields, a drag
    // of the list or the Done pill closes the keyboard (unfocus only — the
    // wipe rules above are unchanged).
    final content = KeyboardDismissRegion(
      child: Listener(
        onPointerDown: (_) => _session.touch(),
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          // Side insets keep the cards clear of the Dynamic Island / cutout
          // in landscape; the 20 pt gutters sit on top of them.
          padding: EdgeInsets.fromLTRB(
            padding.left,
            padding.top + 8,
            padding.right,
            padding.bottom + 40,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OptionPills<PinTool>(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                options: tools,
                identifiers: [for (final t in tools) 'pin_tool_${t.value.id}'],
                selected: tool,
                onSelected: _selectTool,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 8),
                    PinCaption(l.pinOfflineNote),
                    if (_screenshotsAllowedBuild) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: Semantics(
                          identifier: 'pin_screenshots_allowed',
                          child: PinWarningChip(l.pinScreenshotsAllowedBuild),
                        ),
                      ),
                    ],
                    // PIN 24 shows its own hint next to the seed field.
                    if (tool != PinTool.pin24) _SeedInMemoryRow(_session),
                    // PIN 24 and YubiKey show the reminder next to their field.
                    if (tool == PinTool.pinShift || tool == PinTool.legacyMask)
                      PinClipboardReminder(
                        session: _session,
                        identifier: 'pin_clear_clipboard',
                      ),
                    const SizedBox(height: 6),
                  ],
                ),
              ),
              switch (tool) {
                PinTool.pin24 => const Pin24View(),
                PinTool.pinShift => const PinShiftView(),
                PinTool.yubikey => const YubikeyView(),
                PinTool.legacyMask => const LegacyMaskView(),
              },
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: PinSwitchRow(
                  identifier: 'pin_show_legacy',
                  label: l.pinShowLegacy,
                  caption: l.pinShowLegacyHelp,
                  value: showLegacy,
                  onChanged: (v) => _setShowLegacy(prefs, v),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // A focused field asks its page to stay alive offscreen; the PIN tab
    // never is (leaving it wipes, and the section must really go away).
    return NotificationListener<KeepAliveNotification>(
      onNotification: (_) => true,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Offstage keeps the tools mounted (their input survives a brief
          // `inactive`), but nothing is painted, so the app-switcher snapshot
          // and a recording show only the cover.
          Offstage(
            offstage: veil != PinVeil.none,
            child: TickerMode(enabled: veil == PinVeil.none, child: content),
          ),
          if (veil != PinVeil.none) _PrivacyCover(veil: veil),
        ],
      ),
    );
  }
}

/// "A seed is in memory" with a Wipe button, shown on the other tools while
/// the section still caches the seed entered in PIN 24.
class _SeedInMemoryRow extends StatelessWidget {
  const _SeedInMemoryRow(this.session);

  final PinSession session;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return ListenableBuilder(
      listenable: session.seed,
      builder: (context, _) {
        if (!session.seed.hasSeed) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: PinNotice(
            l.pinSeedInMemory(session.seed.wordCount),
            action: Semantics(
              identifier: 'pin_wipe_cached_seed',
              child: TextButton.icon(
                onPressed: () => session.wipe(
                  scope: PinWipeScope.seed,
                  reason: PinWipeReason.user,
                ),
                icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                label: Text(l.pin24WipeSeed),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Opaque cover over the PIN content while it must not be seen.
class _PrivacyCover extends StatelessWidget {
  const _PrivacyCover({required this.veil});

  final PinVeil veil;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final captured = veil == PinVeil.captured;
    return Semantics(
      identifier: 'pin_privacy_cover',
      container: true,
      child: ColoredBox(
        color: theme.brightness == Brightness.dark
            ? const Color(0xFF0A0A0F)
            : const Color(0xFFF5F5F7),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  captured
                      ? Icons.screen_share_outlined
                      : Icons.visibility_off_outlined,
                  size: 64,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: 16),
                Text(
                  captured ? l.pinHiddenCaptured : l.pinHiddenInactive,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium,
                ),
                if (captured) ...[
                  const SizedBox(height: 8),
                  Text(
                    l.pinHiddenCapturedHint,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
