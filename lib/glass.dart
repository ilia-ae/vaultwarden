import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// The app's single motion feel: an underdamped spring (ζ=0.8) with a
/// barely-there overshoot. Use this everywhere instead of Curves.* so all
/// motion shares one physical character.
class AppSpringCurve extends Curve {
  const AppSpringCurve();

  static const _zeta = 0.8;
  static const _omega = 12.0;

  @override
  double transformInternal(double t) {
    final od = _omega * math.sqrt(1 - _zeta * _zeta);
    return 1 -
        math.exp(-_zeta * _omega * t) *
            (math.cos(od * t) + (_zeta * _omega / od) * math.sin(od * t));
  }
}

const appSpring = AppSpringCurve();

/// Press-feedback wrapper: scales to 0.97 while pressed, springs back on
/// release. Uses [Listener] so it never competes with the child's own tap
/// handling. Honours Reduce Motion.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child});

  final Widget child;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final instant = MediaQuery.disableAnimationsOf(context);
    return Listener(
      onPointerDown: (_) => setState(() => _down = true),
      onPointerUp: (_) => setState(() => _down = false),
      onPointerCancel: (_) => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.97 : 1.0,
        duration: instant
            ? Duration.zero
            : Duration(milliseconds: _down ? 90 : 350),
        curve: appSpring,
        child: widget.child,
      ),
    );
  }
}

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
        // needing a backdrop shader. Dark surface sits ~6% above the scene
        // base so the superellipse corners actually read (on #0A0A0F a
        // #16161D card was edge-invisible — only the top hairline showed).
        color: dark ? const Color(0xFA1C1D26) : const Color(0xFAFFFFFF),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(
            width: 0.5,
            color: dark
                ? Colors.white.withValues(alpha: 0.10)
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
/// Glass tuned for the edge-to-edge top bar. `thickness`/`lightIntensity`
/// create the refraction rim that, on a full-bleed bar, reads as an ugly
/// frame — so they're near-zero here: a clean frosted blur with a stronger
/// surface tint instead of a rimmed glass panel.
LiquidGlassSettings barGlassFor(Brightness brightness) =>
    brightness == Brightness.dark
        ? const LiquidGlassSettings(
            glassColor: Color(0xC612131A), // stronger tint, no visible rim
            blur: 18,
            thickness: 0,
            lightIntensity: 0,
            chromaticAberration: 0,
            saturation: 1.2,
          )
        : const LiquidGlassSettings(
            glassColor: Color(0xD6F2F4FA),
            blur: 18,
            thickness: 0,
            lightIntensity: 0,
            chromaticAberration: 0,
            saturation: 1.2,
          );

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
