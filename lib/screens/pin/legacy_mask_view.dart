import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../pin_tools/mask_pin.dart';
import '../../pin_tools/pin_shift.dart' show normalizeInputDigits;
import '../../pin_tools/python_text.dart' show hasLoneSurrogate, pythonStrip;
import 'pin_session.dart';
import 'pin_widgets.dart';

/// Legacy mask (`pass_pin`): an 8-digit mask walked over a 20-character
/// string (core in `lib/pin_tools/mask_pin.dart`). Shown only with "Show
/// legacy tools" on.
///
/// Superseded by PIN Shift (personal-crypto-tools `pin/README.md`); kept to
/// recover PINs made with the archived script. Generate-only. The mask
/// accepts ASCII `0`–`9` only, on purpose (the Python `int()` also took
/// other digit scripts). Both inputs live only in this widget and are
/// cleared by every section wipe, by Clear and when the widget goes away.
/// Errors come from [MaskPinException.code] as fixed localized strings and
/// never quote the input.
class LegacyMaskView extends ConsumerStatefulWidget {
  const LegacyMaskView({super.key});

  @override
  ConsumerState<LegacyMaskView> createState() => _LegacyMaskViewState();
}

/// State of the mask field.
enum _MaskState { empty, incomplete, invalid, ok }

class _LegacyMaskViewState extends ConsumerState<LegacyMaskView> {
  late final ProviderSubscription<PinSession> _sessionSub;
  late final PinSession _session;
  VoidCallback? _unregisterProbe;

  final _maskCtrl = TextEditingController();
  final _inputCtrl = TextEditingController();

  // Reveal toggles: off on every visit, after every wipe and on Clear.
  bool _showMask = false;
  bool _showInput = false;
  bool _reveal = false;

  /// Bumped by every wipe and Clear: the fields are rebuilt with an empty
  /// undo history.
  int _fieldGen = 0;

  @override
  void initState() {
    super.initState();
    _sessionSub = ref.listenManual(pinSessionProvider, (_, __) {});
    _session = _sessionSub.read();
    _session.wipes.addListener(_onWipe);
    _unregisterProbe = _session.registerContentProbe(_hasContent);
    _session.touch();
  }

  @override
  void dispose() {
    _session.wipes.removeListener(_onWipe);
    _unregisterProbe?.call();
    _sessionSub.close();
    _maskCtrl.clear();
    _inputCtrl.clear();
    _maskCtrl.dispose();
    _inputCtrl.dispose();
    TextInput.finishAutofillContext(shouldSave: false);
    super.dispose();
  }

  bool _hasContent() => _maskCtrl.text.isNotEmpty || _inputCtrl.text.isNotEmpty;

  void _onWipe() {
    final event = _session.wipes.value;
    if (event == null || !mounted) return;
    if (event.scope == PinWipeScope.seed) return; // nothing seed-related here
    _clearInputs();
  }

  void _clearInputs() {
    _maskCtrl.clear();
    _inputCtrl.clear();
    TextInput.finishAutofillContext(shouldSave: false);
    setState(() {
      _fieldGen++;
      _showMask = false;
      _showInput = false;
      _reveal = false;
    });
  }

  void _onClearPressed() {
    _session.touch();
    HapticFeedback.mediumImpact();
    FocusManager.instance.primaryFocus?.unfocus();
    _clearInputs();
    _session.userCleared();
  }

  void _edited(String _) {
    _session.touch();
    setState(() {});
  }

  String _errorText(AppLocalizations l, MaskPinException e) => switch (e.code) {
        MaskPinException.codeMaskFormat => l.pinLegacyErrMaskFormat,
        MaskPinException.codeInputLength => l.pinLegacyErrInputLength,
        MaskPinException.codeMaskValueRange =>
          l.pinLegacyErrMaskValueRange(e.position ?? 0),
        _ => l.pinFixErrorsAbove,
      };

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;

    // Mask: stripped like the script's main() (generate_pin itself does not
    // strip), then checked by the core.
    final mask = pythonStrip(_maskCtrl.text);
    final maskLength = mask.runes.length;
    final otherScriptDigits = normalizeInputDigits(mask) != mask;
    _MaskState maskState;
    String? maskError;
    var maskHasZero = false;
    List<int> positions = const [];
    if (mask.isEmpty) {
      maskState = _MaskState.empty;
    } else if (maskLength < kMaskLength &&
        mask.runes.every((r) => r >= 0x30 && r <= 0x39)) {
      maskState = _MaskState.incomplete;
    } else {
      try {
        positions = maskPinPositions(mask);
        maskState = _MaskState.ok;
      } on MaskPinException catch (e) {
        maskState = _MaskState.invalid;
        maskError = _errorText(l, e);
        maskHasZero = e.code == MaskPinException.codeMaskValueRange;
      }
    }

    final input = _inputCtrl.text;
    final inputCount = maskInputLength(input);
    final broken = hasLoneSurrogate(input);
    String? inputError;
    if (broken) {
      inputError = l.pinLegacyInputBroken;
    } else if (inputCount > kMaskInputLength) {
      inputError = l.pinLegacyErrInputLength;
    }
    final inputReady = !broken && inputCount == kMaskInputLength;

    String? output;
    String? outputError;
    if (maskState == _MaskState.ok && inputReady) {
      try {
        output = maskPin(mask, input);
      } on MaskPinException catch (e) {
        outputError = _errorText(l, e);
      }
    }

    return Semantics(
      identifier: 'legacy_mask_view',
      container: true,
      explicitChildNodes: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _introCard(l),
          _maskCard(l, maskLength, maskError, otherScriptDigits, maskHasZero),
          _inputCard(l, inputCount, inputError),
          _outputCard(
            l,
            hasErrors: maskError != null || inputError != null,
            output: output,
            outputError: outputError,
            mask: maskState == _MaskState.ok ? mask : null,
            positions: positions,
            input: input,
          ),
          _aboutCard(l),
        ],
      ),
    );
  }

  Widget _introCard(AppLocalizations l) {
    final theme = Theme.of(context);
    return PinCard(
      children: [
        // Wrap, not Row: at large text the badge moves under the title
        // instead of squeezing it letter by letter.
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Icon(Icons.history_toggle_off, color: theme.colorScheme.primary),
            Text(l.pinToolLegacy, style: theme.textTheme.titleLarge),
            Semantics(
              identifier: 'legacy_mask_badge',
              child: PinWarningChip(l.pinLegacyBadge),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Semantics(
          identifier: 'legacy_mask_banner',
          child: PinBanner(child: Text(l.pinLegacyBanner)),
        ),
        const SizedBox(height: 10),
        Text(l.pinLegacyHow, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        PinCaption(l.pinLegacyNotPorted),
      ],
    );
  }

  Widget _eye({
    required AppLocalizations l,
    required String identifier,
    required String field,
    required bool shown,
    required VoidCallback onPressed,
  }) {
    return Semantics(
      identifier: identifier,
      child: IconButton(
        tooltip: shown ? l.pinHideField(field) : l.pinShowField(field),
        icon: Icon(shown ? Icons.visibility_off_outlined : Icons.visibility),
        onPressed: () {
          _session.touch();
          onPressed();
        },
      ),
    );
  }

  Widget _counter(String id, int count, int target) {
    final theme = Theme.of(context);
    final color = count == target
        ? PinColors.okText(theme.brightness)
        : (count > target
            ? theme.colorScheme.error
            : theme.colorScheme.onSurfaceVariant);
    return Semantics(
      identifier: id,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Text('$count / $target', style: pinMono(context, color: color)),
      ),
    );
  }

  Widget _maskCard(
    AppLocalizations l,
    int maskLength,
    String? error,
    bool otherScriptDigits,
    bool hasZero,
  ) {
    return PinCard(
      title: l.pinLegacySectionMask,
      children: [
        PinSecretField(
          controller: _maskCtrl,
          identifier: 'legacy_mask_mask',
          wipeGeneration: _fieldGen,
          obscure: !_showMask,
          pasteOnlyMenu: true,
          monospace: true,
          textDirection: TextDirection.ltr,
          keyboardType: TextInputType.number,
          labelText: l.pinLegacyMaskLabel,
          helperText: l.pinLegacyMaskHelp,
          onChanged: _edited,
          suffixIcon: _eye(
            l: l,
            identifier: 'legacy_mask_mask_eye',
            field: l.pinLegacyMaskLabel,
            shown: _showMask,
            onPressed: () => setState(() => _showMask = !_showMask),
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: _counter('legacy_mask_mask_count', maskLength, kMaskLength),
        ),
        if (error != null)
          Semantics(
            identifier: 'legacy_mask_mask_error',
            child: PinNotice(error, kind: PinNoticeKind.error),
          ),
        // The script's message names a 1–20 range nobody can type in a
        // one-digit mask; say what to change.
        if (hasZero)
          Semantics(
            identifier: 'legacy_mask_zero_hint',
            child: PinNotice(l.pinLegacyMaskZeroHint),
          ),
        if (otherScriptDigits)
          Semantics(
            identifier: 'legacy_mask_mask_ascii_hint',
            child: PinNotice(l.pinLegacyMaskAsciiOnly,
                kind: PinNoticeKind.warning),
          ),
      ],
    );
  }

  Widget _inputCard(AppLocalizations l, int count, String? error) {
    return PinCard(
      title: l.pinLegacySectionInput,
      children: [
        PinSecretField(
          controller: _inputCtrl,
          identifier: 'legacy_mask_input',
          wipeGeneration: _fieldGen,
          obscure: !_showInput,
          pasteOnlyMenu: true,
          monospace: true,
          textDirection: TextDirection.ltr,
          labelText: l.pinLegacyInputLabel,
          helperText: l.pinLegacyInputHelp,
          onChanged: _edited,
          suffixIcon: _eye(
            l: l,
            identifier: 'legacy_mask_input_eye',
            field: l.pinLegacyInputLabel,
            shown: _showInput,
            onPressed: () => setState(() => _showInput = !_showInput),
          ),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: _counter('legacy_mask_input_count', count, kMaskInputLength),
        ),
        if (error != null)
          Semantics(
            identifier: 'legacy_mask_input_error',
            child: PinNotice(error, kind: PinNoticeKind.error),
          ),
      ],
    );
  }

  Widget _outputCard(
    AppLocalizations l, {
    required bool hasErrors,
    required String? output,
    required String? outputError,
    required String? mask,
    required List<int> positions,
    required String input,
  }) {
    final body = <Widget>[
      PinSwitchRow(
        identifier: 'legacy_mask_reveal',
        icon: Icons.visibility_outlined,
        label: l.pinLegacyReveal,
        caption: l.pinLegacyRevealHelp,
        value: _reveal,
        onChanged: (v) {
          _session.touch();
          setState(() => _reveal = v);
        },
      ),
      const SizedBox(height: 8),
    ];

    if (hasErrors) {
      body.add(Semantics(
        identifier: 'legacy_mask_fix_errors',
        child: PinNotice(l.pinFixErrorsAbove),
      ));
    } else if (outputError != null) {
      body.add(PinNotice(outputError, kind: PinNoticeKind.error));
    } else if (output == null) {
      body
        ..add(_CharCells(
          chars: List.filled(kMaskLength, '•'),
          color: PinColors.emptyText,
          identifier: 'legacy_mask_output',
          semanticLabel: l.pinLegacyOutputEmpty,
        ))
        ..add(const SizedBox(height: 6))
        ..add(Semantics(
          identifier: 'legacy_mask_incomplete',
          child: PinCaption(l.pinLegacyIncomplete),
        ));
    } else {
      final chars = [for (final r in output.runes) String.fromCharCode(r)];
      body
        ..add(_CharCells(
          chars: chars,
          color: PinColors.valid,
          identifier: 'legacy_mask_output',
          // Read aloud only while "Show the walk" is on (one rule for every
          // PIN tool: secrets are spoken only when revealed).
          semanticLabel: _reveal
              ? l.pinLegacyOutputSemantics(chars.join(' '))
              : l.pinSecretHiddenSemantics(
                  l.pinLegacySectionOutput, chars.length),
        ))
        ..add(const SizedBox(height: 8))
        ..add(PinCaption(l.pinLegacyOutputCaption));
      if (chars.any((c) => !_isAsciiDigit(c))) {
        body.add(Semantics(
          identifier: 'legacy_mask_not_numeric',
          child: PinNotice(l.pinLegacyNotNumeric, kind: PinNoticeKind.info),
        ));
      }
    }

    // Revisits force '0' — a property of the mask alone, so it is shown as
    // soon as the mask is valid (the steps themselves only with 👁).
    if (mask != null && !hasErrors) {
      final revisits = maskPinRevisitSteps(mask);
      if (revisits.isNotEmpty) {
        body.add(Semantics(
          identifier: 'legacy_mask_revisit_warning',
          child: PinNotice(
            l.pinLegacyRevisitWarning(revisits.length),
            kind: PinNoticeKind.warning,
          ),
        ));
        if (_reveal) {
          body.add(Semantics(
            identifier: 'legacy_mask_revisit_steps',
            child: PinCaption(l.pinLegacyRevisitSteps(
                ltrIsolate(revisits.map((i) => '${i + 1}').join(', ')))),
          ));
        }
      }
      if (_reveal) {
        body
          ..add(const SizedBox(height: 8))
          ..add(Semantics(
            identifier: 'legacy_mask_positions',
            child: PinCaption(l.pinLegacyVisited(
                ltrIsolate(positions.map((p) => '${p + 1}').join(', ')))),
          ));
        if (output != null) {
          body
            ..add(const SizedBox(height: 8))
            ..add(_WalkGrid(input: input, positions: positions));
        }
      }
    }

    body.addAll([
      const SizedBox(height: 12),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: Semantics(
          identifier: 'legacy_mask_clear',
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
            onPressed: _onClearPressed,
            icon: const Icon(Icons.backspace_outlined, size: 18),
            label: Text(l.clear),
          ),
        ),
      ),
    ]);
    return PinCard(title: l.pinLegacySectionOutput, children: body);
  }

  static bool _isAsciiDigit(String c) =>
      c.length == 1 && c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

  Widget _aboutCard(AppLocalizations l) {
    final theme = Theme.of(context);
    return PinCard(
      children: [
        PinDisclosure(
          title: l.pinLegacyAboutTitle,
          identifier: 'legacy_mask_about',
          children: [
            Text(
              l.pinLegacyAboutBody,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
            ),
          ],
        ),
      ],
    );
  }
}

/// Up to eight output characters in cells, left-to-right. Works on code
/// points, so an emoji is one cell.
class _CharCells extends StatelessWidget {
  const _CharCells({
    required this.chars,
    required this.color,
    required this.identifier,
    required this.semanticLabel,
  });

  final List<String> chars;
  final Color color;
  final String identifier;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: identifier,
      container: true,
      label: semanticLabel,
      child: ExcludeSemantics(
        child: PinDigitCells.chars(
          chars: chars,
          color: color,
          fontSize: 26,
        ),
      ),
    );
  }
}

/// The 20 characters of the string with the walk drawn over them (shown
/// only with 👁, since it reveals both the string and the mask).
class _WalkGrid extends StatelessWidget {
  const _WalkGrid({required this.input, required this.positions});

  final String input;
  final List<int> positions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final elements = [
      for (final r in normalizeMaskInput(input).runes) String.fromCharCode(r),
    ];
    final steps = <int, List<int>>{};
    for (var i = 0; i < positions.length; i++) {
      steps.putIfAbsent(positions[i], () => []).add(i + 1);
    }
    return Semantics(
      identifier: 'legacy_mask_walk',
      container: true,
      child: ExcludeSemantics(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (var p = 0; p < elements.length; p++)
                _walkCell(context, theme, p, elements[p], steps[p]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _walkCell(BuildContext context, ThemeData theme, int position,
      String char, List<int>? visits) {
    final revisited = visits != null && visits.length > 1;
    final color = visits == null
        ? theme.colorScheme.outlineVariant
        : (revisited ? PinColors.partial : PinColors.valid);
    final labelColor = visits == null
        ? theme.colorScheme.onSurfaceVariant
        : PinColors.textFor(color, theme.brightness);
    final scaler = MediaQuery.textScalerOf(context);
    final labelSize = scaler.scale(9);
    final charSize = scaler.scale(16);
    // Position, visits and character each on their own line, so nothing
    // overlaps at any text size.
    return Container(
      constraints: BoxConstraints(
        minWidth: math.max(44, labelSize * 4.5),
        minHeight: math.max(50, labelSize * 2.6 + charSize * 1.4 + 6),
      ),
      padding: const EdgeInsets.fromLTRB(4, 2, 4, 3),
      decoration: ShapeDecoration(
        color:
            visits == null ? Colors.transparent : color.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: color, width: visits == null ? 1 : 1.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${position + 1}',
              style: TextStyle(
                  fontSize: 9, height: 1.2, color: theme.colorScheme.outline)),
          Text(
            visits == null ? ' ' : '→${visits.join(',')}',
            style: TextStyle(
              fontSize: 9,
              height: 1.2,
              color: labelColor,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(char, style: pinMono(context, size: 16)),
        ],
      ),
    );
  }
}
