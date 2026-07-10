import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// Shared, deliberately strong Liquid Glass look for the app's frosted
/// surfaces (settings sheet, request cards, …). Higher blur + thickness +
/// specular highlight than the package defaults for a clear iOS 26 feel.
const appGlass = LiquidGlassSettings(
  blur: 18,
  thickness: 34,
  lightIntensity: 0.7,
  refractiveIndex: 1.35,
  chromaticAberration: 0.03,
  saturation: 1.55,
);
