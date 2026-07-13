import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Full-screen scene background that sits under every screen.
///
/// Glass overlays only read as glass over a rich backdrop — on a flat
/// surface the refraction is invisible. The scene is a near-black (or
/// near-white) base with two STATIC radial glows plus a subtle noise
/// grain that dithers away gradient banding. Nothing animates here, and
/// the whole scene lives inside a [RepaintBoundary], so scrolling content
/// above never repaints it.
class AppBackground extends StatelessWidget {
  const AppBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        Positioned.fill(
          child: RepaintBoundary(child: _Scene(dark: dark)),
        ),
        child,
      ],
    );
  }
}

class _Scene extends StatefulWidget {
  const _Scene({required this.dark});

  final bool dark;

  @override
  State<_Scene> createState() => _SceneState();
}

class _SceneState extends State<_Scene> {
  static ui.Image? _noise; // decoded once per process, shared

  @override
  void initState() {
    super.initState();
    _loadNoise();
  }

  Future<void> _loadNoise() async {
    if (_noise != null) return;
    final data = await rootBundle.load('assets/textures/noise128.png');
    final codec =
        await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    if (mounted) setState(() => _noise = frame.image);
    codec.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _ScenePainter(dark: widget.dark, noise: _noise),
      size: Size.infinite,
    );
  }
}

class _ScenePainter extends CustomPainter {
  _ScenePainter({required this.dark, required this.noise});

  final bool dark;
  final ui.Image? noise;

  // Near-black, not pure #000 — pure black kills the refraction on OLED.
  static const _darkBase = Color(0xFF0A0A0F);
  static const _lightBase = Color(0xFFF5F5F7);
  static const _indigo = Color(0xFF1B1E4B);
  static const _violet = Color(0xFF2A1B4B);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(rect, Paint()..color = dark ? _darkBase : _lightBase);

    // Static radial glows. Opacity per spec: dark ~10-12% / ~8%,
    // light ~5-6%.
    _glow(canvas, rect,
        center: Offset(size.width * 0.08, size.height * 0.06),
        radius: size.width * 0.70,
        color: _indigo,
        opacity: dark ? 0.11 : 0.06);
    _glow(canvas, rect,
        center: Offset(size.width * 0.92, size.height * 0.94),
        radius: size.width * 0.60,
        color: _violet,
        opacity: dark ? 0.08 : 0.05);

    // Grain: tiled noise composited with overlay blend at ~2.5% so the
    // gradients dither instead of banding.
    final n = noise;
    if (n != null) {
      final layerPaint = Paint()
        ..blendMode = BlendMode.overlay
        ..color = Colors.white.withValues(alpha: 0.025);
      canvas.saveLayer(rect, layerPaint);
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ImageShader(
            n,
            TileMode.repeated,
            TileMode.repeated,
            Matrix4.identity().storage,
          ),
      );
      canvas.restore();
    }
  }

  void _glow(Canvas canvas, Rect rect,
      {required Offset center,
      required double radius,
      required Color color,
      required double opacity}) {
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [color.withValues(alpha: opacity), color.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(_ScenePainter old) =>
      old.dark != dark || old.noise != noise;
}
