import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../glass.dart';
import 'segmented_tabs.dart';

/// Section title above a group of controls: `labelLarge` in
/// `onSurfaceVariant`, the settings sheet's header look.
class SectionHeader extends StatelessWidget {
  const SectionHeader(
    this.title, {
    super.key,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final String title;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// Single-choice selection pills (the settings sheet's option chips as a
/// reusable widget).
///
/// Neutral, like the [SegmentedTabs] pickers (the accent is kept for the
/// top-tab underline and Approve): selected = a filled grey stadium with the
/// label in `onSurface`, semibold (no Material checkmark); unselected = a
/// hairline-outlined stadium with the label in `onSurfaceVariant`. Press
/// gives the app-wide spring squish and a selection haptic. [onSelected]
/// fires on every tap, including a tap on the pill that is already selected.
class OptionPills<T> extends StatelessWidget {
  const OptionPills({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.identifiers,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final List<({T value, String label})> options;

  /// The selected value, or `null`/a value not in [options] for none.
  final T? selected;
  final ValueChanged<T> onSelected;

  /// Optional Semantics identifiers, one per option (Maestro flows).
  final List<String>? identifiers;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var i = 0; i < options.length; i++)
            OptionPill(
              label: options[i].label,
              selected: options[i].value == selected,
              identifier: identifiers != null && i < identifiers!.length
                  ? identifiers![i]
                  : null,
              onTap: () => onSelected(options[i].value),
            ),
        ],
      ),
    );
  }
}

/// Multi-choice variant of [OptionPills]: each pill toggles on its own.
class MultiOptionPills<T> extends StatelessWidget {
  const MultiOptionPills({
    super.key,
    required this.options,
    required this.selected,
    required this.onToggled,
    this.identifiers,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
  });

  final List<({T value, String label})> options;
  final Set<T> selected;
  final ValueChanged<T> onToggled;
  final List<String>? identifiers;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var i = 0; i < options.length; i++)
            OptionPill(
              label: options[i].label,
              selected: selected.contains(options[i].value),
              identifier: identifiers != null && i < identifiers!.length
                  ? identifiers![i]
                  : null,
              onTap: () => onToggled(options[i].value),
            ),
        ],
      ),
    );
  }
}

/// One stadium pill. Content-sized; see [OptionPills] for the look.
class OptionPill extends StatelessWidget {
  const OptionPill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.identifier,
    this.icon,
    this.semanticsLabel,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? identifier;

  /// Optional leading icon (e.g. where an option comes from).
  final IconData? icon;

  /// What a screen reader says instead of [label] (e.g. with the source).
  final String? semanticsLabel;

  /// Fill of a selected pill (also the setup screen's server pills): the
  /// [SegmentedTabs] greys, never the accent. Its lighter thumb in the dark
  /// theme; in the light theme its track grey, as a white thumb would vanish
  /// on the white cards the pills sit on.
  static Color selectedFill(Brightness brightness) =>
      brightness == Brightness.dark
          ? SegmentedTabs.thumbColor(brightness)
          : SegmentedTabs.trackColor(brightness);

  /// Label colour: `onSurface` when selected (as the selected segment's
  /// label), `onSurfaceVariant` otherwise.
  static Color labelColor(ColorScheme cs, {required bool selected}) =>
      selected ? cs.onSurface : cs.onSurfaceVariant;

  /// Outline of an unselected pill; a selected one has none.
  static BorderSide unselectedSide(ColorScheme cs) =>
      BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Pressable(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Semantics(
          identifier: identifier,
          button: true,
          selected: selected,
          label: semanticsLabel,
          excludeSemantics: semanticsLabel != null,
          child: Container(
            // No `alignment` here: a Container with alignment expands to the
            // parent's max width, which in a Wrap stretches every pill
            // full-width. Padding alone keeps them content-sized.
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: ShapeDecoration(
              color: selected
                  ? selectedFill(theme.brightness)
                  : Colors.transparent,
              shape: StadiumBorder(
                side: selected ? BorderSide.none : unselectedSide(cs),
              ),
            ),
            child: _content(theme, cs),
          ),
        ),
      ),
    );
  }

  Widget _content(ThemeData theme, ColorScheme cs) {
    final color = labelColor(cs, selected: selected);
    final style = theme.textTheme.labelLarge?.copyWith(
      color: color,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
    );
    final leading = icon;
    if (leading == null) return Text(label, style: style);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(leading, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
  }
}
