import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

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
