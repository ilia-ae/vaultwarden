import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsRole;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../glass.dart';

/// Glass navigation bar: screen-centered title, right-side actions and the
/// screen's primary tabs (text labels with an accent underline, see
/// [_TextTabs]).
///
/// Title centering: the title lives in a full-width [Stack] layer with
/// SYMMETRIC horizontal padding, so its center is the screen's center —
/// never the leftover space between neighbours (the Row/Expanded drift
/// bug). Actions float above it in a [Positioned]; on narrow screens the
/// [FittedBox] shrinks the title before it can collide.
class GlassTopBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassTopBar({
    super.key,
    required this.title,
    required this.controller,
    required this.tabs,
    this.tabIdentifiers,
    this.actions,
  });

  final String title;
  final TabController controller;
  final List<String> tabs;

  /// Optional Semantics identifiers per tab (screenshot flows rely on them).
  final List<String>? tabIdentifiers;
  final List<Widget>? actions;

  static const double toolbarHeight = 52;

  /// The tab row. Each tab takes the whole height of it (≥ 48 pt targets).
  static const double tabsHeight = 48;

  /// The active tab's underline (tests find it by this key).
  static const Key underlineKey = ValueKey<String>('GlassTopBar.underline');

  @override
  Size get preferredSize => const Size.fromHeight(toolbarHeight + tabsHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The list scrolls UNDER the bar, and glass does not take hits: without
    // this a tap or drag on an empty part of the bar (status-bar strip,
    // beside the title, the tab row's margins) reached whatever card was
    // scrolled beneath it — e.g. its Approve button. Like a UIKit bar, the
    // whole bar now takes its own pointers.
    return Listener(
      behavior: HitTestBehavior.opaque,
      child: _bar(theme),
    );
  }

  Widget _bar(ThemeData theme) {
    return GlassContainer(
      // Square shape: the bar bleeds edge-to-edge, no corner rounding.
      shape: const LiquidRoundedRectangle(borderRadius: 0),
      // Static surface -> premium is affordable per the design spec.
      // premium REQUIRES its own LiquidGlassLayer (package asserts otherwise).
      useOwnLayer: true,
      quality: GlassQuality.premium,
      // barGlassFor kills the refraction rim so the bar has no frame.
      settings: barGlassFor(theme.brightness),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            SizedBox(
              height: toolbarHeight,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Padding(
                      // Symmetric => optical center == screen center.
                      padding: const EdgeInsets.symmetric(horizontal: 104),
                      child: Align(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            title,
                            maxLines: 1,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (actions != null)
                    // Directional: trailing edge — flips to the left in RTL.
                    PositionedDirectional(
                      end: 4,
                      top: 0,
                      bottom: 0,
                      child: Row(
                          mainAxisSize: MainAxisSize.min, children: actions!),
                    ),
                ],
              ),
            ),
            SizedBox(
              height: tabsHeight,
              child: _TextTabs(
                controller: controller,
                labels: tabs,
                identifiers: tabIdentifiers,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The screen's primary tabs: plain text labels on the bar's glass, the
/// active one bright and the others muted, and a short accent underline
/// under the active label. No droplet, no frame: this level reads as
/// screen navigation, while the neutral [SegmentedTabs]-style control below
/// it switches content inside a tab.
///
/// The underline follows [TabController.animation]: a tap glides it with
/// [appSpring] (instantly under Reduce Motion), a swipe of the pages drags
/// it along. It is as wide as the label it sits under (never under
/// [_minUnderline]) and changes width on the way to the next one.
///
/// Every tab is a full cell of the row ([GlassTopBar.tabsHeight] tall, half
/// the width for two tabs), so the tap target is well over 48 × 48 pt.
class _TextTabs extends StatelessWidget {
  const _TextTabs({
    required this.controller,
    required this.labels,
    this.identifiers,
  });

  final TabController controller;
  final List<String> labels;
  final List<String>? identifiers;

  static const double _labelSize = 15;
  static const double _margin = 16;
  static const double _hPad = 12;
  static const double _underlineHeight = 3;

  /// Gap between the underline and the bottom edge of the bar.
  static const double _underlineBottom = 7;

  /// The label is centred in the row above this strip, so the underline
  /// sits close under its baseline.
  static const double _labelBottom = 6;
  static const double _minUnderline = 24;

  /// Muted (inactive) label: the active colour at this opacity — still
  /// ≥ 4.5:1 on the bar's glass in both themes.
  static const double _mutedAlpha = 0.64;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final n = labels.length;
    final animation = controller.animation!;
    // One weight for every state: selecting a tab never reflows its label,
    // so the underline measured below always matches it.
    final style = DefaultTextStyle.of(context).style.merge(const TextStyle(
          fontSize: _labelSize,
          fontWeight: FontWeight.w600,
          // A tight line box: the label sits close above its underline.
          height: 1.2,
        ));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _margin),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final cell = constraints.maxWidth / n;
          final box = Size(
            math.max(cell - 2 * _hPad, 1),
            math.max(constraints.maxHeight - _labelBottom, 1),
          );
          final widths = [
            for (final label in labels) _labelWidth(context, label, style, box),
          ];
          return Stack(
            children: [
              ListenableBuilder(
                // The selected state follows the index.
                listenable: controller,
                builder: (context, _) => Semantics(
                  container: true,
                  role: SemanticsRole.tabBar,
                  explicitChildNodes: true,
                  child: Row(
                    children: [
                      for (var i = 0; i < n; i++)
                        Expanded(child: _tab(context, i, style, cs)),
                    ],
                  ),
                ),
              ),
              AnimatedBuilder(
                animation: animation,
                builder: (context, _) {
                  final value = animation.value.clamp(0.0, n - 1.0);
                  final from = value.floor();
                  final to = math.min(from + 1, n - 1);
                  final width = lerpDouble(
                    math.max(widths[from], _minUnderline),
                    math.max(widths[to], _minUnderline),
                    value - from,
                  )!;
                  // Directional: in RTL the first tab sits on the right, and
                  // the underline must follow it there.
                  return PositionedDirectional(
                    key: GlassTopBar.underlineKey,
                    start: (value + 0.5) * cell - width / 2,
                    bottom: _underlineBottom,
                    width: width,
                    height: _underlineHeight,
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          color: cs.primary,
                          shape: const StadiumBorder(),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _tab(BuildContext context, int i, TextStyle style, ColorScheme cs) {
    final ids = identifiers;
    final animation = controller.animation!;
    return Semantics(
      container: true,
      identifier: ids != null && i < ids.length ? ids[i] : null,
      role: SemanticsRole.tab,
      button: true,
      selected: controller.index == i,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          controller.animateTo(
            i,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 450),
            curve: appSpring,
          );
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(_hPad, 0, _hPad, _labelBottom),
          child: Center(
            child: AnimatedBuilder(
              animation: animation,
              builder: (context, _) {
                // 1 at the active tab, fading with distance.
                final active =
                    (1 - (animation.value - i).abs()).clamp(0.0, 1.0);
                return FittedBox(
                  // A huge text scale shrinks the label to the fixed-height
                  // bar instead of clipping it.
                  fit: BoxFit.scaleDown,
                  child: Text(
                    labels[i],
                    maxLines: 1,
                    softWrap: false,
                    style: style.copyWith(
                      color: Color.lerp(
                        cs.onSurface.withValues(alpha: _mutedAlpha),
                        cs.onSurface,
                        active,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// The label's painted width in [box], after the [FittedBox] scale-down.
  static double _labelWidth(
    BuildContext context,
    String label,
    TextStyle style,
    Size box,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
      locale: Localizations.maybeLocaleOf(context),
      textHeightBehavior: DefaultTextHeightBehavior.maybeOf(context),
    )..layout();
    final size = painter.size;
    painter.dispose();
    final scale = math.min(
      1.0,
      math.min(box.width / size.width, box.height / size.height),
    );
    return size.width * scale;
  }
}
