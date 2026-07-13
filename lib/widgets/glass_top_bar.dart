import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../glass.dart';

/// Glass navigation bar: screen-centered title, right-side actions and a
/// segmented tab switcher with a glass droplet indicator.
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
  static const double tabsHeight = 54;

  @override
  Size get preferredSize =>
      const Size.fromHeight(toolbarHeight + tabsHeight);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GlassContainer(
      // Square shape: the bar bleeds edge-to-edge, no corner rounding.
      shape: const LiquidRoundedRectangle(borderRadius: 0),
      // Static surface -> premium is affordable per the design spec.
      // premium REQUIRES its own LiquidGlassLayer (package asserts otherwise).
      useOwnLayer: true,
      quality: GlassQuality.premium,
      settings: appGlassFor(theme.brightness),
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
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (actions != null)
                    Positioned(
                      right: 4,
                      top: 0,
                      bottom: 0,
                      child: Row(mainAxisSize: MainAxisSize.min,
                          children: actions!),
                    ),
                ],
              ),
            ),
            SizedBox(
              height: tabsHeight,
              child: _GlassTabs(
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

/// Segmented switcher: labels in an even row, a glass droplet glides to the
/// active tab following [TabController.animation] (so swipes track too).
class _GlassTabs extends StatelessWidget {
  const _GlassTabs({
    required this.controller,
    required this.labels,
    this.identifiers,
  });

  final TabController controller;
  final List<String> labels;
  final List<String>? identifiers;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = labels.length;
    final animation = controller.animation!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: Stack(
        children: [
          // Glass droplet indicator.
          AnimatedBuilder(
            animation: animation,
            builder: (context, _) {
              final t = n == 1 ? 0.0 : animation.value / (n - 1);
              return Align(
                alignment: Alignment(t * 2 - 1, 0),
                child: FractionallySizedBox(
                  widthFactor: 1 / n,
                  heightFactor: 1,
                  child: GlassContainer(
                    shape:
                        const LiquidRoundedSuperellipse(borderRadius: 21),
                    quality: GlassQuality.standard,
                    settings: appGlassFor(theme.brightness),
                    child: const SizedBox.expand(),
                  ),
                ),
              );
            },
          ),
          Row(
            children: [
              for (var i = 0; i < n; i++)
                Expanded(
                  child: Semantics(
                    identifier: identifiers != null && i < identifiers!.length
                        ? identifiers![i]
                        : null,
                    button: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => controller.animateTo(
                        i,
                        duration: const Duration(milliseconds: 450),
                        curve: Curves.easeOutBack, // spring-like overshoot
                      ),
                      child: Center(
                        child: AnimatedBuilder(
                          animation: animation,
                          builder: (context, _) {
                            // 1 at the active tab, fades with distance.
                            final active = (1 -
                                    (animation.value - i).abs())
                                .clamp(0.0, 1.0);
                            return Text(
                              labels[i],
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.lerp(
                                    FontWeight.w500,
                                    FontWeight.w700,
                                    active),
                                color: Color.lerp(
                                  theme.colorScheme.onSurfaceVariant,
                                  theme.colorScheme.onSurface,
                                  active,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
