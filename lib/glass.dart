import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// Opaque content-layer card.
///
/// iOS 26 grammar: glass is ONLY the navigation/overlay layer — content
/// (request cards, lists, fields) stays opaque. Superellipse geometry
/// matches the glass overlays' shapes, a 0.5px light hairline fakes
/// top-light, and a large soft shadow lifts the card off the scene
/// background.
class ContentCard extends StatelessWidget {
  const ContentCard({
    super.key,
    required this.child,
    this.margin,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsetsGeometry? margin;
  final EdgeInsetsGeometry padding;

  static const radius = 26.0;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: margin,
      padding: padding,
      decoration: ShapeDecoration(
        // ~98% opaque: a hint of the scene glow tints the surface without
        // needing a backdrop shader.
        color: dark ? const Color(0xFA16161D) : const Color(0xFAFFFFFF),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(
            width: 0.5,
            color: dark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.05),
          ),
        ),
        shadows: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? 0.30 : 0.12),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// Shared Liquid Glass look for the app's frosted surfaces (settings sheet,
/// request cards, …), tuned per theme brightness.
///
/// The glassColor tint is what keeps content readable: pure transparent glass
/// over a dimmed modal barrier reads as a muddy grey veil, so each theme gets
/// a translucent surface tint close to its own surface color instead.
LiquidGlassSettings appGlassFor(Brightness brightness) =>
    brightness == Brightness.dark
        ? const LiquidGlassSettings(
            glassColor: Color(0xB816161C), // ~72% dark surface tint
            blur: 12,
            thickness: 22,
            lightIntensity: 0.55,
            refractiveIndex: 1.25,
            chromaticAberration: 0.015,
            saturation: 1.35,
          )
        : const LiquidGlassSettings(
            glassColor: Color(0xC2F6F8FC), // ~76% light surface tint
            blur: 12,
            thickness: 22,
            lightIntensity: 0.6,
            refractiveIndex: 1.25,
            chromaticAberration: 0.015,
            saturation: 1.35,
          );
