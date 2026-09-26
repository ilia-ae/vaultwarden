/// Building blocks shared by the PIN tools: a hardened text field for
/// secrets, the BIP39 word-cell mirror, big digit cells, notices, the orange
/// banner, warning chips and a tap-to-copy output.
///
/// Every widget that shows digits or words forces left-to-right layout, so
/// they read correctly in Arabic.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../glass.dart';
import '../../l10n/app_localizations.dart';
import '../../pin_tools/bip39.dart';
import '../../pin_tools/python_text.dart' show hasLoneSurrogate;

// ─────────────────────────────────────────────────────────────────────────────
// Colours (from the source page, tuned for both themes)
// ─────────────────────────────────────────────────────────────────────────────

class PinColors {
  static const valid = Color(0xFF2EA043);
  static const partial = Color(0xFFD97706);
  static const invalid = Color(0xFFD04848);
  static const emptyBorderDark = Color(0xFF3F4756);
  static const emptyText = Color(0xFF5A6273);
  static const index = Color(0xFF6B7280);
  static const info = Color(0xFF4B6FFF);

  /// Orange banner text: the source's #E89A3C on dark, a darker amber on
  /// light for contrast.
  static Color bannerText(Brightness b) =>
      b == Brightness.dark ? const Color(0xFFE89A3C) : const Color(0xFF9A4D00);
}

/// Monospace text style used for words, digits and passwords.
TextStyle pinMono(BuildContext context, {double size = 14, FontWeight? weight,
    Color? color, double? letterSpacing}) {
  return TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: const ['Menlo', 'Courier', 'Roboto Mono'],
    fontSize: size,
    fontWeight: weight ?? FontWeight.w600,
    color: color ?? Theme.of(context).colorScheme.onSurface,
    letterSpacing: letterSpacing,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Hardened text field
// ─────────────────────────────────────────────────────────────────────────────

/// A text field for secrets and secret-adjacent values.
///
/// * Keyboard learning, suggestions, autocorrect, smart quotes/dashes,
///   spell check, auto-capitalisation, handwriting and autofill are off.
/// * No `restorationId`, so the value never enters state restoration.
/// * [obscure]: always masked, with no reveal button; the context menu offers
///   only Paste (copy/cut are impossible on masked fields anyway). On iOS
///   16+ that is the native menu (no "Allow Paste" prompt), elsewhere a
///   Flutter menu whose Paste keeps line breaks as spaces ([normalizePaste]).
/// * [onPasted] fires after a paste through the Flutter menu. Pastes the
///   field cannot see (iOS native menu, keyboard clipboard) are detected by
///   the owner from the size of the edit, see [pasteThreshold].
/// * A visible (not [obscure]) field drops unpaired UTF-16 surrogates, which
///   the text engine cannot lay out, and reports it via
///   [onBrokenCharactersRemoved]. Masked fields keep them (they render as
///   bullets), so the derivation reports them as an error instead.
class PinSecretField extends StatefulWidget {
  const PinSecretField({
    super.key,
    required this.controller,
    required this.identifier,
    this.focusNode,
    this.obscure = true,
    this.enabled = true,
    this.labelText,
    this.hintText,
    this.helperText,
    this.onChanged,
    this.onPasted,
    this.normalizePaste,
    this.onBrokenCharactersRemoved,
    this.monospace = false,
  });

  final TextEditingController controller;

  /// Semantics identifier (Maestro), e.g. `pin24_seed`.
  final String identifier;
  final FocusNode? focusNode;
  final bool obscure;
  final bool enabled;
  final String? labelText;
  final String? hintText;
  final String? helperText;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onPasted;

  /// Applied to clipboard text pasted through the Flutter menu.
  final String Function(String pasted)? normalizePaste;
  final VoidCallback? onBrokenCharactersRemoved;
  final bool monospace;

  /// An insertion this long in one edit is treated as a paste.
  static const pasteThreshold = 8;

  @override
  State<PinSecretField> createState() => _PinSecretFieldState();
}

class _PinSecretFieldState extends State<PinSecretField> {
  Future<void> _paste(EditableTextState state) async {
    state.hideToolbar();
    ClipboardData? data;
    try {
      data = await Clipboard.getData(Clipboard.kTextPlain);
    } catch (_) {
      return;
    }
    final raw = data?.text;
    if (raw == null || raw.isEmpty || !mounted) return;
    final insert = widget.normalizePaste?.call(raw) ?? raw;
    final value = state.textEditingValue;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    state.userUpdateTextEditingValue(
      value.replaced(selection, insert),
      SelectionChangedCause.toolbar,
    );
    // Reported even when the insert is short: it still came from the clipboard.
    if (!mounted) return;
    widget.onPasted?.call();
  }

  Widget _pasteOnlyMenu(BuildContext context, EditableTextState state) {
    if (SystemContextMenu.isSupportedByField(state)) {
      return SystemContextMenu.editableText(
        editableTextState: state,
        items: const [IOSSystemContextMenuItemPaste()],
      );
    }
    if (!state.pasteEnabled) return const SizedBox.shrink();
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: [
        ContextMenuButtonItem(
          type: ContextMenuButtonType.paste,
          onPressed: () => _paste(state),
        ),
      ],
    );
  }

  /// The platform's usual menu, for fields that are not secret.
  static Widget _defaultMenu(BuildContext context, EditableTextState state) {
    if (SystemContextMenu.isSupportedByField(state)) {
      return SystemContextMenu.editableText(editableTextState: state);
    }
    return AdaptiveTextSelectionToolbar.editableText(editableTextState: state);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      identifier: widget.identifier,
      child: TextField(
        controller: widget.controller,
        focusNode: widget.focusNode,
        enabled: widget.enabled,
        obscureText: widget.obscure,
        obscuringCharacter: '•',
        maxLines: 1,
        keyboardType: widget.obscure
            ? TextInputType.text
            : TextInputType.visiblePassword,
        textCapitalization: TextCapitalization.none,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
        autofillHints: null,
        stylusHandwritingEnabled: false,
        contextMenuBuilder: widget.obscure ? _pasteOnlyMenu : _defaultMenu,
        inputFormatters: widget.obscure
            ? null
            : [_DropLoneSurrogates(widget.onBrokenCharactersRemoved)],
        onChanged: widget.onChanged,
        style: widget.monospace
            ? pinMono(context, size: 16, weight: FontWeight.w500)
            : null,
        decoration: InputDecoration(
          labelText: widget.labelText,
          hintText: widget.hintText,
          helperText: widget.helperText,
          helperMaxLines: 4,
          hintMaxLines: 1,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          filled: true,
          fillColor: theme.colorScheme.surfaceContainerHighest
              .withValues(alpha: 0.35),
        ),
      ),
    );
  }
}

/// Removes unpaired UTF-16 surrogates (they cannot be painted, and no
/// device could hold them as UTF-8).
class _DropLoneSurrogates extends TextInputFormatter {
  _DropLoneSurrogates(this.onRemoved);

  final VoidCallback? onRemoved;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final text = newValue.text;
    if (!hasLoneSurrogate(text)) return newValue;
    final out = StringBuffer();
    var cursor = newValue.selection.isValid
        ? newValue.selection.extentOffset
        : text.length;
    final originalCursor = cursor;
    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c >= 0xD800 && c <= 0xDBFF && i + 1 < text.length) {
        final next = text.codeUnitAt(i + 1);
        if (next >= 0xDC00 && next <= 0xDFFF) {
          out.write(text.substring(i, i + 2));
          i++;
          continue;
        }
      }
      if (c >= 0xD800 && c <= 0xDFFF) {
        if (i < originalCursor) cursor--;
        continue;
      }
      out.writeCharCode(c);
    }
    onRemoved?.call();
    final cleaned = out.toString();
    return TextEditingValue(
      text: cleaned,
      selection: TextSelection.collapsed(
        offset: cursor.clamp(0, cleaned.length),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Word-cell mirror
// ─────────────────────────────────────────────────────────────────────────────

/// Mirror of the typed BIP39 words: [target] cells in groups of four, each
/// with its 1-based index and a validation colour.
///
/// With [reveal] off every typed word shows the same fixed mask (`••••`), so
/// neither the word nor its length leaks; colours stay visible. Screen
/// readers get "Word 3, valid" — never the word.
class PinWordCells extends StatelessWidget {
  const PinWordCells({
    super.key,
    required this.words,
    required this.states,
    required this.target,
    required this.reveal,
  });

  final List<String> words;
  final List<Bip39WordState> states;
  final int target;
  final bool reveal;

  /// Fixed-width mask for every typed word.
  static const mask = '••••';

  @override
  Widget build(BuildContext context) {
    const cellGap = 6.0;
    const groupGap = 12.0;
    const minCell = 62.0;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          const minGroup = 4 * minCell + 3 * cellGap;
          final perRow =
              ((width + groupGap) / (minGroup + groupGap)).floor().clamp(1, 4);
          final groupWidth = (width - (perRow - 1) * groupGap) / perRow;
          final cellWidth = (groupWidth - 3 * cellGap) / 4;
          final groups = <Widget>[];
          for (var g = 0; g < target; g += 4) {
            groups.add(SizedBox(
              width: groupWidth,
              child: Row(
                children: [
                  for (var i = g; i < g + 4 && i < target; i++) ...[
                    if (i > g) const SizedBox(width: cellGap),
                    _WordCell(
                      index: i,
                      width: cellWidth,
                      word: i < words.length ? words[i] : null,
                      state: i < states.length ? states[i] : null,
                      reveal: reveal,
                    ),
                  ],
                ],
              ),
            ));
          }
          return Wrap(spacing: groupGap, runSpacing: 6, children: groups);
        },
      ),
    );
  }
}

class _WordCell extends StatelessWidget {
  const _WordCell({
    required this.index,
    required this.width,
    required this.word,
    required this.state,
    required this.reveal,
  });

  final int index;
  final double width;
  final String? word;
  final Bip39WordState? state;
  final bool reveal;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final Color border;
    final Color fill;
    final String stateLabel;
    switch (state) {
      case Bip39WordState.valid:
        border = PinColors.valid;
        fill = PinColors.valid.withValues(alpha: 0.12);
        stateLabel = l.pinWordStateValid;
      case Bip39WordState.partial:
        border = PinColors.partial;
        fill = PinColors.partial.withValues(alpha: 0.12);
        stateLabel = l.pinWordStatePartial;
      case Bip39WordState.invalid:
        border = PinColors.invalid;
        fill = PinColors.invalid.withValues(alpha: 0.12);
        stateLabel = l.pinWordStateInvalid;
      case null:
        border = dark
            ? PinColors.emptyBorderDark
            : Theme.of(context).colorScheme.outlineVariant;
        fill = Colors.transparent;
        stateLabel = l.pinWordStateEmpty;
    }
    final text = word == null ? '•' : (reveal ? word! : PinWordCells.mask);
    return Semantics(
      label: l.pinWordCellSemantics(index + 1, stateLabel),
      container: true,
      child: ExcludeSemantics(
        child: Container(
          width: width,
          height: 42,
          decoration: ShapeDecoration(
            color: fill,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: border, width: 1.2),
            ),
          ),
          child: Stack(
            children: [
              Positioned(
                left: 4,
                top: 2,
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(fontSize: 9, color: PinColors.index),
                ),
              ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(6, 8, 6, 2),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      text,
                      maxLines: 1,
                      style: pinMono(
                        context,
                        size: 13,
                        color: word == null ? PinColors.emptyText : null,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Digit cells
// ─────────────────────────────────────────────────────────────────────────────

/// Large digit cells, left-to-right, in groups of four joined by `–`.
class PinDigitCells extends StatelessWidget {
  const PinDigitCells({
    super.key,
    required this.value,
    this.cellWidth = 40,
    this.cellHeight = 56,
    this.fontSize = 28,
    this.color = PinColors.valid,
  });

  final String value;
  final double cellWidth;
  final double cellHeight;
  final double fontSize;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final groups = <Widget>[];
    for (var g = 0; g < value.length; g += 4) {
      final end = g + 4 > value.length ? value.length : g + 4;
      if (g > 0) {
        groups.add(SizedBox(
          height: cellHeight,
          child: Center(
            child: Text(
              '–',
              style: pinMono(context, size: fontSize * 0.7, color: color),
            ),
          ),
        ));
      }
      groups.add(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = g; i < end; i++) ...[
            if (i > g) const SizedBox(width: 4),
            Container(
              width: cellWidth,
              height: cellHeight,
              alignment: Alignment.center,
              decoration: ShapeDecoration(
                color: color.withValues(alpha: 0.14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: color.withValues(alpha: 0.55)),
                ),
              ),
              child: Text(
                value[i],
                style: pinMono(
                  context,
                  size: fontSize,
                  weight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
          ],
        ],
      ));
    }
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        runSpacing: 8,
        children: groups,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Notices, banner, chips
// ─────────────────────────────────────────────────────────────────────────────

enum PinNoticeKind { ok, info, warning, error }

/// One status line with an icon: green ok, blue info, orange warning, red
/// error.
class PinNotice extends StatelessWidget {
  const PinNotice(this.text, {super.key, this.kind = PinNoticeKind.info});

  final String text;
  final PinNoticeKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (IconData icon, Color color) = switch (kind) {
      PinNoticeKind.ok => (Icons.check_circle_outline, PinColors.valid),
      PinNoticeKind.info => (Icons.info_outline, PinColors.info),
      PinNoticeKind.warning => (Icons.warning_amber_rounded, PinColors.partial),
      PinNoticeKind.error => (Icons.error_outline, theme.colorScheme.error),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: kind == PinNoticeKind.info
                    ? theme.colorScheme.onSurface
                    : color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The orange "recovery only" banner: amber tint, hairline, 4 px leading bar.
class PinBanner extends StatelessWidget {
  const PinBanner({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Container(
      decoration: BoxDecoration(
        color: PinColors.partial.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PinColors.partial.withValues(alpha: 0.45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 4, color: PinColors.partial),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: DefaultTextStyle.merge(
                  style: TextStyle(
                    color: PinColors.bannerText(brightness),
                    height: 1.35,
                  ),
                  child: child,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small orange chip for a soft, non-blocking warning.
class PinWarningChip extends StatelessWidget {
  const PinWarningChip(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: ShapeDecoration(
        color: PinColors.partial.withValues(alpha: 0.12),
        shape: StadiumBorder(
          side: BorderSide(color: PinColors.partial.withValues(alpha: 0.5)),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 16, color: PinColors.partial),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PinColors.bannerText(brightness),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A card section of a PIN tool: opaque [ContentCard] with an optional
/// header line.
class PinCard extends StatelessWidget {
  const PinCard({super.key, this.title, required this.children});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ContentCard(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            Text(title!, style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
          ],
          ...children,
        ],
      ),
    );
  }
}

/// A caption in `bodySmall` / `onSurfaceVariant`.
class PinCaption extends StatelessWidget {
  const PinCaption(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        height: 1.35,
      ),
    );
  }
}

/// A collapsible block (passphrase, threat model). Children are built only
/// while expanded.
class PinDisclosure extends StatelessWidget {
  const PinDisclosure({
    super.key,
    required this.title,
    required this.children,
    this.identifier,
    this.initiallyExpanded = false,
  });

  final String title;
  final List<Widget> children;
  final String? identifier;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: Semantics(
        identifier: identifier,
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          shape: const Border(),
          collapsedShape: const Border(),
          title: Text(title, style: Theme.of(context).textTheme.titleSmall),
          children: children,
        ),
      ),
    );
  }
}

/// A switch row with a label and an optional caption.
class PinSwitchRow extends StatelessWidget {
  const PinSwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.caption,
    this.identifier,
  });

  final String label;
  final String? caption;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? identifier;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: identifier,
      child: SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        subtitle: caption == null ? null : PinCaption(caption!),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tap-to-copy output
// ─────────────────────────────────────────────────────────────────────────────

/// Wraps an output: a tap runs [onCopy] (which copies through the privacy
/// channel and reports success) and flashes "✓ Copied!" or "✗ Failed" for
/// 1.2 s.
class PinCopyable extends StatefulWidget {
  const PinCopyable({
    super.key,
    required this.child,
    required this.onCopy,
    required this.semanticLabel,
    this.identifier,
  });

  final Widget child;
  final Future<bool> Function() onCopy;

  /// Read by screen readers instead of the (secret) content.
  final String semanticLabel;
  final String? identifier;

  @override
  State<PinCopyable> createState() => _PinCopyableState();
}

class _PinCopyableState extends State<PinCopyable> {
  bool? _result;
  Timer? _timer;

  Future<void> _copy() async {
    HapticFeedback.lightImpact();
    final ok = await widget.onCopy();
    if (!mounted) return;
    _timer?.cancel();
    setState(() => _result = ok);
    _timer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _result = null);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Semantics(
      identifier: widget.identifier,
      button: true,
      label: widget.semanticLabel,
      hint: l.pinCopyHint,
      container: true,
      child: Pressable(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _copy,
          child: Stack(
            alignment: Alignment.center,
            children: [
              ExcludeSemantics(child: widget.child),
              if (_result != null)
                Positioned.fill(
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surface.withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _result! ? l.pinCopied : l.pinCopyFailed,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: _result!
                            ? PinColors.valid
                            : theme.colorScheme.error,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
