import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import '../glass.dart';

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
/// iOS-26 grammar matching the app's Approve/Deny/tab language: selected = a
/// soft accent stadium (no Material checkmark), unselected = a
/// hairline-outlined stadium. Press gives the app-wide spring squish and a
/// selection haptic. [onSelected] fires on every tap, including a tap on the
/// pill that is already selected.
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
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final String? identifier;

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
          child: Container(
            // No `alignment` here: a Container with alignment expands to the
            // parent's max width, which in a Wrap stretches every pill
            // full-width. Padding alone keeps them content-sized.
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: ShapeDecoration(
              color: selected ? cs.primaryContainer : Colors.transparent,
              shape: StadiumBorder(
                side: selected
                    ? BorderSide.none
                    : BorderSide(
                        color: cs.outlineVariant.withValues(alpha: 0.6),
                      ),
              ),
            ),
            child: Text(
              label,
              style: theme.textTheme.labelLarge?.copyWith(
                color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
