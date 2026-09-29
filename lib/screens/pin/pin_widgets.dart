/// Building blocks shared by the PIN tools: a hardened text field for
/// secrets, the BIP39 word-cell mirror, big digit cells, notices, the orange
/// banner, warning chips, a tap-to-copy output, the clipboard reminder and
/// the dialogs a wipe closes.
///
/// Every widget that shows digits or words forces left-to-right layout, so
/// they read correctly in Arabic. Cells size themselves from the user's text
/// scale ([MediaQuery.textScalerOf]).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../glass.dart';
import '../../l10n/app_localizations.dart';
import '../../pin_tools/bip39.dart';
import '../../pin_tools/python_text.dart' show hasLoneSurrogate;
import '../../services/privacy_service.dart';
import 'pin_session.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Colours (from the source page, tuned for both themes)
// ─────────────────────────────────────────────────────────────────────────────

class PinColors {
  /// Source colours: borders, fills and icons.
  static const valid = Color(0xFF2EA043);
  static const partial = Color(0xFFD97706);
  static const invalid = Color(0xFFD04848);
  static const emptyBorderDark = Color(0xFF3F4756);
  static const emptyText = Color(0xFF5A6273);
  static const index = Color(0xFF6B7280);
  static const info = Color(0xFF4B6FFF);

  // Text colours. The source colours are too light for text on the light
  // card (#2EA043 is 3.4:1) and on their own 14 % tint in the dark theme, so
  // text uses these per-theme variants: at least 4.5:1 (WCAG AA) on the card
  // and on a 10–14 % tint of the source colour (pin_colors_test.dart).

  /// Green text (OK notices, output digits).
  static Color okText(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF3FB950) : const Color(0xFF137333);

  /// Amber text (warnings, banner, chips, vector digits).
  static Color warningText(Brightness b) =>
      b == Brightness.dark ? const Color(0xFFE89A3C) : const Color(0xFF9A4D00);

  /// Blue text (input digits).
  static Color infoText(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF7C95FF) : const Color(0xFF2F4FD8);

  /// Orange banner text: the source's #E89A3C on dark, a darker amber on
  /// light for contrast.
  static Color bannerText(Brightness b) => warningText(b);

  /// The text colour that goes with a source colour.
  static Color textFor(Color source, Brightness b) {
    if (source == valid) return okText(b);
    if (source == partial) return warningText(b);
    if (source == info) return infoText(b);
    return source;
  }

  /// The opaque card surface the PIN content sits on (ContentCard over the
  /// scene), for contrast checks.
  static Color cardSurface(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF1C1D26) : const Color(0xFFFFFFFF);
}

/// Wraps [text] in a left-to-right isolate (U+2066 … U+2069), so maths,
/// arrows, number lists and codes inserted into an Arabic sentence keep
/// their order (`10^4` would otherwise read `4^10`). Invisible elsewhere.
String ltrIsolate(String text) => '\u2066$text\u2069';

/// Monospace text style used for words, digits and passwords.
TextStyle pinMono(BuildContext context,
    {double size = 14,
    FontWeight? weight,
    Color? color,
    double? letterSpacing}) {
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
/// * [obscure]: masked, with no reveal button of its own; the context menu
///   offers only Paste (copy/cut are impossible on masked fields anyway). On
///   iOS 16+ that is the native menu (no "Allow Paste" prompt), elsewhere a
///   Flutter menu whose Paste keeps line breaks as spaces ([normalizePaste]).
///   Tools whose spec has a per-field eye (PIN Shift, legacy mask) flip
///   [obscure] from a [suffixIcon] and keep [pasteOnlyMenu] on, so a revealed
///   secret still cannot be copied out. The seed field never gets one.
/// * Secret fields ([pasteOnlyMenu], default [obscure]) also ignore the
///   Copy/Cut keyboard shortcuts (Ctrl/Cmd+C/X on a hardware keyboard), which
///   would otherwise put a revealed secret on the plain clipboard, bypassing
///   [PrivacyService.copySensitive].
/// * Undo/Redo shortcuts are off, and every change of [wipeGeneration]
///   rebuilds the field with an empty undo history: a wiped value can never
///   be brought back with Ctrl+Z or the iOS shake / three-finger undo.
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
    this.textDirection,
    this.keyboardType,
    this.suffixIcon,
    this.pasteOnlyMenu,
    this.maxLines = 1,
    this.wipeGeneration = 0,
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

  /// Forces a direction, e.g. LTR for BIP39 words in an RTL locale.
  final TextDirection? textDirection;

  /// Overrides the keyboard (default: text when [obscure], else
  /// visible-password), e.g. [TextInputType.number] for digit secrets.
  final TextInputType? keyboardType;

  /// Trailing widget inside the field, e.g. a show/hide toggle for a secret
  /// the tool lets the user reveal (PIN Shift, legacy mask).
  final Widget? suffixIcon;

  /// Offer only Paste in the context menu and ignore Copy/Cut shortcuts
  /// (default: when [obscure]). Set it for a secret that is currently
  /// revealed, so it still cannot be copied or cut out of the field.
  final bool? pasteOnlyMenu;

  /// Lines of a visible field (a list of serials); masked fields always
  /// have one.
  final int maxLines;

  /// Bump on every wipe and Clear: the field is rebuilt from scratch, so its
  /// undo history (which holds every earlier value in plain text) is gone.
  final int wipeGeneration;

  /// An insertion this long in one edit is treated as a paste.
  static const pasteThreshold = 8;

  @override
  State<PinSecretField> createState() => _PinSecretFieldState();
}

class _PinSecretFieldState extends State<PinSecretField> {
  /// Owned per [PinSecretField.wipeGeneration]; replaced (and its history
  /// dropped) whenever the generation changes.
  UndoHistoryController _undo = UndoHistoryController();

  @override
  void didUpdateWidget(PinSecretField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.wipeGeneration != widget.wipeGeneration) {
      final old = _undo;
      _undo = UndoHistoryController();
      // The old field (and its UndoHistory) is unmounted in this frame and
      // detaches from the controller while doing so.
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  @override
  void dispose() {
    _undo.dispose();
    super.dispose();
  }

  static Object? _ignore(Intent _) => null;

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
    final secret = widget.pasteOnlyMenu ?? widget.obscure;
    final field = TextField(
      // A new key per generation: a fresh EditableText and UndoHistory.
      key: ValueKey<int>(widget.wipeGeneration),
      controller: widget.controller,
      focusNode: widget.focusNode,
      undoController: _undo,
      enabled: widget.enabled,
      obscureText: widget.obscure,
      obscuringCharacter: '•',
      maxLines: widget.obscure ? 1 : widget.maxLines,
      minLines: 1,
      textDirection: widget.textDirection,
      keyboardType: widget.keyboardType ??
          (widget.obscure ? TextInputType.text : TextInputType.visiblePassword),
      textCapitalization: TextCapitalization.none,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      smartDashesType: SmartDashesType.disabled,
      smartQuotesType: SmartQuotesType.disabled,
      spellCheckConfiguration: const SpellCheckConfiguration.disabled(),
      autofillHints: null,
      stylusHandwritingEnabled: false,
      contextMenuBuilder: secret ? _pasteOnlyMenu : _defaultMenu,
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
        helperMaxLines: 8,
        hintMaxLines: 1,
        suffixIcon: widget.suffixIcon,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        filled: true,
        fillColor:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      ),
    );
    return Semantics(
      identifier: widget.identifier,
      // The field's own actions defer to these (they are "overridable"):
      // the shortcut is consumed and nothing happens.
      child: Actions(
        actions: <Type, Action<Intent>>{
          UndoTextIntent: CallbackAction<UndoTextIntent>(onInvoke: _ignore),
          RedoTextIntent: CallbackAction<RedoTextIntent>(onInvoke: _ignore),
          if (secret)
            CopySelectionTextIntent:
                CallbackAction<CopySelectionTextIntent>(onInvoke: _ignore),
        },
        child: field,
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
///
/// Cells grow with the text scale; the index sits on its own line above the
/// word, and when a group of four no longer fits one line it wraps to two
/// (or one) cells per line.
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

  static const _wordSize = 13.0;
  static const _indexSize = 9.0;

  @override
  Widget build(BuildContext context) {
    const cellGap = 6.0;
    const groupGap = 12.0;
    final scaler = MediaQuery.textScalerOf(context);
    final wordSize = scaler.scale(_wordSize);
    final indexSize = scaler.scale(_indexSize);
    // An 8-letter word at the user's text size (cells may shrink 10 %; the
    // word then scales down a little).
    final minCell = 62.0 * wordSize / _wordSize;
    final cellHeight = math.max(42.0, 6 + indexSize * 1.3 + wordSize * 1.4 + 4);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          double need(int n) => n * minCell * 0.9 + (n - 1) * cellGap;
          final perLine = need(4) <= width ? 4 : (need(2) <= width ? 2 : 1);
          final groupsPerRow = perLine < 4
              ? 1
              : ((width + groupGap) / (4 * minCell + 3 * cellGap + groupGap))
                  .floor()
                  .clamp(1, 4);
          final groupWidth =
              (width - (groupsPerRow - 1) * groupGap) / groupsPerRow;
          final cellWidth = (groupWidth - (perLine - 1) * cellGap) / perLine;
          Widget cell(int i) => _WordCell(
                index: i,
                width: cellWidth,
                height: cellHeight,
                wordSize: _wordSize,
                indexSize: _indexSize,
                word: i < words.length ? words[i] : null,
                state: i < states.length ? states[i] : null,
                reveal: reveal,
              );
          final groups = <Widget>[];
          for (var g = 0; g < target; g += 4) {
            final end = math.min(g + 4, target);
            final lines = <Widget>[];
            for (var l = g; l < end; l += perLine) {
              lines.add(Row(
                children: [
                  for (var i = l; i < l + perLine && i < end; i++) ...[
                    if (i > l) const SizedBox(width: cellGap),
                    cell(i),
                  ],
                ],
              ));
            }
            groups.add(SizedBox(
              width: groupWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < lines.length; i++) ...[
                    if (i > 0) const SizedBox(height: cellGap),
                    lines[i],
                  ],
                ],
              ),
            ));
          }
          return Wrap(
            spacing: groupGap,
            runSpacing: perLine < 4 ? groupGap : cellGap,
            children: groups,
          );
        },
      ),
    );
  }
}

class _WordCell extends StatelessWidget {
  const _WordCell({
    required this.index,
    required this.width,
    required this.height,
    required this.wordSize,
    required this.indexSize,
    required this.word,
    required this.state,
    required this.reveal,
  });

  final int index;
  final double width;
  final double height;
  final double wordSize;
  final double indexSize;
  final String? word;
  final Bip39WordState? state;
  final bool reveal;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
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
        border =
            dark ? PinColors.emptyBorderDark : theme.colorScheme.outlineVariant;
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
          height: height,
          padding: const EdgeInsets.fromLTRB(5, 3, 5, 3),
          decoration: ShapeDecoration(
            color: fill,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(color: border, width: 1.2),
            ),
          ),
          // Index on its own line: it never overlaps the word, at any scale.
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${index + 1}',
                maxLines: 1,
                style: TextStyle(
                  fontSize: indexSize,
                  height: 1.1,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              Expanded(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      text,
                      maxLines: 1,
                      style: pinMono(
                        context,
                        size: wordSize,
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

/// Large digit (or character) cells, left-to-right, in groups of four.
///
/// Cells grow with the text scale and shrink (down to what the glyph needs)
/// so that as many whole groups as possible share a line: an 8-digit PIN
/// fits one line on a phone. Groups on the same line are joined by a dash;
/// a group that starts a new line gets none, so no dash is left alone.
class PinDigitCells extends StatelessWidget {
  PinDigitCells({
    super.key,
    required String value,
    this.cellWidth = 40,
    this.cellHeight = 56,
    this.fontSize = 28,
    this.color = PinColors.valid,
  }) : chars = [for (final r in value.runes) String.fromCharCode(r)];

  /// One cell per entry (code points, so an emoji is one cell).
  const PinDigitCells.chars({
    super.key,
    required this.chars,
    this.cellWidth = 40,
    this.cellHeight = 56,
    this.fontSize = 28,
    this.color = PinColors.valid,
  });

  final List<String> chars;

  /// Width at text scale 1.0 when there is room.
  final double cellWidth;
  final double cellHeight;
  final double fontSize;

  /// Source colour (fill, border); the text uses [PinColors.textFor].
  final Color color;

  static const _cellGap = 4.0;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final textColor = PinColors.textFor(color, brightness);
    final scaler = MediaQuery.textScalerOf(context);
    final fs = scaler.scale(fontSize);
    final factor = fs / fontSize;
    final height = math.max(cellHeight * math.min(factor, 1.5), fs * 1.5 + 4);
    // Monospace digit ≈ 0.62 em, plus a little air.
    final minWidth = fs * 0.62 + 6;
    final maxWidth = math.max(cellWidth, minWidth);
    final dashWidth = math.max(12.0, fs * 0.45);
    const dashGap = 6.0;
    final groups = <List<String>>[
      for (var g = 0; g < chars.length; g += 4)
        chars.sublist(g, math.min(g + 4, chars.length)),
    ];

    return Directionality(
      textDirection: TextDirection.ltr,
      child: LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth;
        var perLine = 1;
        var cell = maxWidth;
        for (var k = groups.length; k >= 1; k--) {
          final n = groups.take(k).fold<int>(0, (a, g) => a + g.length);
          final w = (width -
                  (n - k) * _cellGap -
                  (k - 1) * (dashWidth + 2 * dashGap)) /
              n;
          if (w >= minWidth || k == 1) {
            perLine = k;
            cell = math.min(w, maxWidth);
            break;
          }
        }
        Widget groupRow(List<String> group) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < group.length; i++) ...[
                  if (i > 0) const SizedBox(width: _cellGap),
                  Container(
                    width: cell,
                    height: height,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: ShapeDecoration(
                      color: color.withValues(alpha: 0.14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(color: color.withValues(alpha: 0.55)),
                      ),
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        group[i],
                        maxLines: 1,
                        style: pinMono(
                          context,
                          size: fontSize,
                          weight: FontWeight.w700,
                          color: textColor,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            );
        final dash = Padding(
          padding: const EdgeInsets.symmetric(horizontal: dashGap),
          child: Container(
            width: dashWidth,
            height: math.max(3.0, fs * 0.1),
            decoration: BoxDecoration(
              color: textColor,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        );
        final lines = <Widget>[];
        for (var g = 0; g < groups.length; g += perLine) {
          lines.add(Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = g; i < g + perLine && i < groups.length; i++) ...[
                if (i > g) dash,
                groupRow(groups[i]),
              ],
            ],
          ));
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < lines.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              lines[i],
            ],
          ],
        );
      }),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Notices, banner, chips
// ─────────────────────────────────────────────────────────────────────────────

enum PinNoticeKind { ok, info, warning, error }

/// One status line with an icon: green ok, blue info, orange warning, red
/// error. An optional [action] (e.g. "Clear clipboard") sits under the text,
/// aligned to the end, so neither squeezes the other at large text sizes.
class PinNotice extends StatelessWidget {
  const PinNotice(
    this.text, {
    super.key,
    this.kind = PinNoticeKind.info,
    this.action,
  });

  final String text;
  final PinNoticeKind kind;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final b = theme.brightness;
    final (IconData icon, Color iconColor, Color textColor) = switch (kind) {
      PinNoticeKind.ok => (
          Icons.check_circle_outline,
          PinColors.okText(b),
          PinColors.okText(b),
        ),
      PinNoticeKind.info => (
          Icons.info_outline,
          PinColors.infoText(b),
          theme.colorScheme.onSurface,
        ),
      PinNoticeKind.warning => (
          Icons.warning_amber_rounded,
          PinColors.warningText(b),
          PinColors.warningText(b),
        ),
      PinNoticeKind.error => (
          Icons.error_outline,
          theme.colorScheme.error,
          theme.colorScheme.error,
        ),
    };
    final line = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: iconColor),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(color: textColor),
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: action == null
          ? line
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                line,
                Align(alignment: AlignmentDirectional.centerEnd, child: action),
              ],
            ),
    );
  }
}

/// The orange "recovery only" banner: amber tint, hairline, 4 px leading bar
/// and a warning icon.
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
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        size: 20, color: PinColors.warningText(brightness)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DefaultTextStyle.merge(
                        style: TextStyle(
                          color: PinColors.bannerText(brightness),
                          height: 1.35,
                        ),
                        child: child,
                      ),
                    ),
                  ],
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
          Icon(Icons.warning_amber_rounded,
              size: 16, color: PinColors.warningText(brightness)),
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
/// while expanded. It opens and closes with the app's spring ([appSpring]),
/// instantly when the system asks to reduce motion. An optional [badge]
/// next to the title says what is inside while it is collapsed.
class PinDisclosure extends StatelessWidget {
  const PinDisclosure({
    super.key,
    required this.title,
    required this.children,
    this.identifier,
    this.initiallyExpanded = false,
    this.badge,
  });

  final String title;
  final List<Widget> children;
  final String? identifier;
  final bool initiallyExpanded;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final instant = MediaQuery.disableAnimationsOf(context);
    final titleText = Text(title, style: theme.textTheme.titleSmall);
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: Semantics(
        identifier: identifier,
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          expansionAnimationStyle: instant
              ? AnimationStyle.noAnimation
              : const AnimationStyle(
                  curve: appSpring,
                  reverseCurve: appSpring,
                  duration: Duration(milliseconds: 450),
                  reverseDuration: Duration(milliseconds: 350),
                ),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          shape: const Border(),
          collapsedShape: const Border(),
          title: badge == null
              ? titleText
              : Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [titleText, PinWarningChip(badge!)],
                ),
          children: children,
        ),
      ),
    );
  }
}

/// A switch row with a label, an optional caption and an optional leading
/// [icon] (e.g. [Icons.visibility_outlined] for the reveal switches).
class PinSwitchRow extends StatelessWidget {
  const PinSwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.caption,
    this.identifier,
    this.icon,
  });

  final String label;
  final String? caption;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? identifier;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      identifier: identifier,
      child: SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero,
        dense: true,
        secondary: icon == null ? null : Icon(icon, size: 20),
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
                    child: Builder(builder: (context) {
                      final color = _result!
                          ? PinColors.okText(theme.brightness)
                          : theme.colorScheme.error;
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(_result! ? Icons.check : Icons.close,
                              color: color),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              _result! ? l.pinCopied : l.pinCopyFailed,
                              style: theme.textTheme.titleMedium?.copyWith(
                                color: color,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      );
                    }),
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
// Dialogs
// ─────────────────────────────────────────────────────────────────────────────

/// [showDialog] for the PIN tools: the dialog is registered with [session],
/// so every full wipe (inactivity, background, 🚨, leaving the tab) closes
/// it and its future completes with `null` — no dialog can act on values
/// that were wiped underneath it.
Future<T?> showPinDialog<T>({
  required BuildContext context,
  required PinSession session,
  required WidgetBuilder builder,
}) {
  BuildContext? dialogContext;
  final unregister = session.registerDialog(() {
    final c = dialogContext;
    if (c == null || !c.mounted) return;
    final route = ModalRoute.of(c);
    if (route != null && route.isActive) {
      route.navigator?.removeRoute(route);
    }
  });
  return showDialog<T>(
    context: context,
    builder: (context) {
      dialogContext = context;
      return builder(context);
    },
  ).whenComplete(unregister);
}

/// How a confirmation looks: [destructive] (red icon and button: the values
/// are gone for good) or [sensitive] (amber warning, normal button: the
/// action exposes secrets but destroys nothing).
enum PinDialogTone { destructive, sensitive }

/// The one confirmation dialog of the PIN tools; `true` only when confirmed.
/// Both buttons carry Semantics identifiers ([confirmId], [cancelId]).
Future<bool> confirmPinAction({
  required BuildContext context,
  required PinSession session,
  required PinDialogTone tone,
  required String title,
  required String body,
  required String confirmLabel,
  required String confirmId,
  required String cancelId,
  IconData? icon,
}) async {
  final l = AppLocalizations.of(context)!;
  final confirmed = await showPinDialog<bool>(
    context: context,
    session: session,
    builder: (context) {
      final theme = Theme.of(context);
      final cs = theme.colorScheme;
      final destructive = tone == PinDialogTone.destructive;
      return AlertDialog(
        scrollable: true,
        icon: Icon(
          icon ??
              (destructive
                  ? Icons.delete_forever_outlined
                  : Icons.warning_amber_rounded),
          color:
              destructive ? cs.error : PinColors.warningText(theme.brightness),
        ),
        title: Text(title),
        content: Text(body),
        actions: [
          Semantics(
            identifier: cancelId,
            child: TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.cancel),
            ),
          ),
          Semantics(
            identifier: confirmId,
            child: FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: cs.error,
                      foregroundColor: cs.onError,
                    )
                  : null,
              onPressed: () => Navigator.pop(context, true),
              child: Text(confirmLabel),
            ),
          ),
        ],
      );
    },
  );
  return confirmed == true;
}

/// What the clipboard does with a copied secret on this platform: iOS keeps
/// it on this device (no Universal Clipboard) and expires it; Android marks
/// it sensitive and clears it after 60 s, which does not stop clipboard-sync
/// apps.
String pinClipboardPrivacyNote(AppLocalizations l) =>
    defaultTargetPlatform == TargetPlatform.iOS
        ? l.pinClipboardNoteIos
        : l.pinClipboardNoteAndroid;

// ─────────────────────────────────────────────────────────────────────────────
// Clipboard reminder
// ─────────────────────────────────────────────────────────────────────────────

/// "The pasted text is still on the clipboard — Clear clipboard", shown while
/// [PinSession.clipboardHoldsPaste] is set (it survives wipes, so it is back
/// after a background wipe).
class PinClipboardReminder extends ConsumerWidget {
  const PinClipboardReminder({
    super.key,
    required this.session,
    required this.identifier,
  });

  final PinSession session;

  /// Semantics identifier of the Clear button.
  final String identifier;

  Future<void> _clear(BuildContext context, PrivacyService privacy) async {
    session.touch();
    await privacy.clearClipboard();
    session.clipboardHoldsPaste.value = false;
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(AppLocalizations.of(context)!.pinClipboardCleared)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context)!;
    final privacy = ref.read(privacyServiceProvider);
    return ValueListenableBuilder<bool>(
      valueListenable: session.clipboardHoldsPaste,
      builder: (context, holds, _) {
        if (!holds) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: PinNotice(
            l.pinPastedStillOnClipboard,
            kind: PinNoticeKind.warning,
            action: Semantics(
              identifier: identifier,
              child: TextButton.icon(
                onPressed: () => _clear(context, privacy),
                icon: const Icon(Icons.content_paste_off_outlined, size: 18),
                label: Text(l.pinClearClipboard),
              ),
            ),
          ),
        );
      },
    );
  }
}
