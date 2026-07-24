import 'dart:ui';

/// Colors sampled from [assets/hero-main.webp], with very dark tones lifted
/// so the preview backdrop never reads as pure black.
abstract final class PreviewHeroPalette {
  static const Color base = Color(0xFF1E1E5A);

  /// Four corner colors for [AnimatedMeshGradient] (exactly four required).
  static const List<Color> meshColors = [
    Color(0xFFF8A8C8),
    Color(0xFF5858A8),
    Color(0xFF382878),
    base,
  ];
}
