import 'dart:ui';

/// Common phone logical viewport (CSS px) — iPhone 14/15 class devices.
const previewPhonePortraitWidth = 390.0;
const previewPhonePortraitHeight = 844.0;

enum PreviewDisplayMode { desktop, phone }

enum PreviewOrientation { portrait, landscape }

enum PreviewViewMode { phonePortrait, phoneLandscape, desktop }

extension PreviewViewModeX on PreviewViewMode {
  PreviewDisplayMode get displayMode => switch (this) {
    PreviewViewMode.desktop => PreviewDisplayMode.desktop,
    PreviewViewMode.phonePortrait || PreviewViewMode.phoneLandscape =>
      PreviewDisplayMode.phone,
  };

  PreviewOrientation get orientation => switch (this) {
    PreviewViewMode.phoneLandscape => PreviewOrientation.landscape,
    PreviewViewMode.desktop || PreviewViewMode.phonePortrait =>
      PreviewOrientation.portrait,
  };
}

Size previewPhoneViewport(PreviewOrientation orientation) {
  return switch (orientation) {
    PreviewOrientation.portrait => const Size(
      previewPhonePortraitWidth,
      previewPhonePortraitHeight,
    ),
    PreviewOrientation.landscape => const Size(
      previewPhonePortraitHeight,
      previewPhonePortraitWidth,
    ),
  };
}

/// Outer frame size including bezel padding around the viewport.
Size previewPhoneFrameSize(PreviewOrientation orientation) {
  const bezel = previewPhoneBezel * 2;
  final viewport = previewPhoneViewport(orientation);
  return Size(viewport.width + bezel, viewport.height + bezel);
}

const previewPhoneBezel = 10.0;
/// Screen corner radius (inner clip).
const previewPhoneCornerRadius = 28.0;
/// Outer frame radius — [previewPhoneCornerRadius] + [previewPhoneBezel] for even bezel at corners.
const previewPhoneOuterCornerRadius =
    previewPhoneCornerRadius + previewPhoneBezel;
const previewPhonePreviewPadding = 16.0;
