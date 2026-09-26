import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../services/privacy_service.dart';
import '../../utils/external_picker.dart';
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

/// The PIN tab: tool picker plus the selected tool.
///
/// Owns the section's safety rules, independent of the app lock timeout
/// (which may be "never") and of demo mode:
/// * `hidden`/`paused` wipes everything (unless a system file picker is
///   open, see [externalPickerActive]); `inactive` only covers the content;
/// * 120 s without interaction wipes everything ([PinSession.touch]);
/// * iOS screen capture covers the content; a screenshot shows a warning with
///   a Wipe action.
///
/// FLAG_SECURE (Android) is switched by `RequestsScreen` from the tab index.
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sessionSub = ref.listenManual(pinSessionProvider, (_, __) {});
    _session = _sessionSub.read();
    _session.wipes.addListener(_onWipe);
    _privacy = ref.read(privacyServiceProvider);
    _events = _privacy.events.listen(_onPrivacyEvent);
    _session.touch();
    unawaited(_checkScreenshotsAllowedBuild());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_events?.cancel());
    _session.wipes.removeListener(_onWipe);
    _sessionSub.close();
    super.dispose();
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

  /// Uses `PrivacyService.isScreenshotsAllowedBuild()` when this build has
  /// it (test builds made with `-Pallow-screenshots=true`), to tell testers
  /// that FLAG_SECURE is not in force. Absent method → no hint.
  Future<void> _checkScreenshotsAllowedBuild() async {
    try {
      final dynamic service = _privacy;
      final Object? allowed = await service.isScreenshotsAllowedBuild();
      if (mounted && allowed == true) {
        setState(() => _screenshotsAllowedBuild = true);
      }
    } catch (_) {
      // Not available in this build.
    }
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
    final l = AppLocalizations.of(context)!;
    final String? message = switch (event.reason) {
      PinWipeReason.user => event.scope == PinWipeScope.seed
          ? l.pinWipedSeed
          : l.pinWipedAll,
      PinWipeReason.screenshot => l.pinWipedAll,
      PinWipeReason.background =>
        event.hadContent ? l.pinWipedBackground : null,
      PinWipeReason.inactivity =>
        event.hadContent ? l.pinWipedInactivity : null,
    };
    if (message == null) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _selectTool(PinTool tool) {
    _session.touch();
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
    final media = MediaQuery.of(context);

    final tools = [
      (value: PinTool.pin24, label: l.pinToolPin24),
      (value: PinTool.pinShift, label: l.pinToolShift),
      (value: PinTool.yubikey, label: l.pinToolYubikey),
      if (showLegacy) (value: PinTool.legacyMask, label: l.pinToolLegacy),
    ];

    final content = Listener(
      onPointerDown: (_) => _session.touch(),
      child: SingleChildScrollView(
        padding: EdgeInsets.only(top: media.padding.top + 8, bottom: 40),
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
                  const SizedBox(height: 4),
                  PinSwitchRow(
                    identifier: 'pin_show_legacy',
                    label: l.pinShowLegacy,
                    caption: l.pinShowLegacyHelp,
                    value: showLegacy,
                    onChanged: (v) => _setShowLegacy(prefs, v),
                  ),
                  PinCaption(l.pinOfflineNote),
                  if (_screenshotsAllowedBuild) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: PinWarningChip(l.pinScreenshotsAllowedBuild),
                    ),
                  ],
                  if (tool != PinTool.pin24) _SeedInMemoryRow(_session),
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
          ],
        ),
      ),
    );

    return Stack(
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
          child: Row(
            children: [
              const Icon(Icons.key_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: PinCaption(l.pinSeedInMemory(session.seed.wordCount)),
              ),
              Semantics(
                identifier: 'pin_wipe_cached_seed',
                child: TextButton(
                  onPressed: () => session.wipe(
                    scope: PinWipeScope.seed,
                    reason: PinWipeReason.user,
                  ),
                  child: Text(l.pin24WipeSeed),
                ),
              ),
            ],
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
