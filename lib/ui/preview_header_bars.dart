import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../preview/preview_device.dart';
import '../preview/preview_mode_controller.dart';
import '../theme/app_theme.dart';
import '../widgets/icon_segmented_control.dart';
import '../widgets/text_segmented_control.dart';

enum _PreviewHeaderLabel { preview }

/// One list, used by the header bar and the compact control bar — two controls
/// drawing the same choice differently is how they drift.
const _viewModeSegments = [
  IconSegment(
    value: PreviewViewMode.phonePortrait,
    tooltip: 'Phone preview',
    icon: LucideIcons.smartphone,
  ),
  IconSegment(
    value: PreviewViewMode.phoneLandscape,
    tooltip: 'Phone preview (landscape)',
    icon: LucideIcons.smartphone,
    iconRotation: 1.5707963267948966,
  ),
  IconSegment(
    value: PreviewViewMode.desktop,
    tooltip: 'Desktop preview',
    icon: LucideIcons.monitor,
  ),
];

const _brightnessSegments = [
  IconSegment(
    value: Brightness.light,
    tooltip: 'App theme: Light',
    icon: LucideIcons.sun,
  ),
  IconSegment(
    value: Brightness.dark,
    tooltip: 'App theme: Dark',
    icon: LucideIcons.moon,
  ),
];

/// The preview pane's header: its label, the view-mode and app-theme
/// switches, and minimize.
class PreviewHeaderBar extends StatelessWidget {
  const PreviewHeaderBar({
    super.key,
    required this.previewBrightness,
    required this.viewMode,
    required this.minimized,
    required this.onPreviewThemeChanged,
    required this.onViewModeChanged,
    required this.onToggleMinimized,
  });

  final Brightness previewBrightness;
  final PreviewViewMode viewMode;
  final bool minimized;
  final ValueChanged<Brightness> onPreviewThemeChanged;
  final ValueChanged<PreviewViewMode> onViewModeChanged;
  final VoidCallback onToggleMinimized;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      height: kPaneHeaderHeight,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: scheme.muted,
        border: Border(bottom: paneBorderSide(scheme.border)),
      ),
      child: Row(
        children: [
          TextSegmentedControl<_PreviewHeaderLabel>(
            value: _PreviewHeaderLabel.preview,
            onChanged: (_) {},
            interactive: false,
            onMutedSurface: true,
            segments: const [
              TextSegment(
                value: _PreviewHeaderLabel.preview,
                label: 'Preview',
              ),
            ],
          ),
          const Spacer(),
          IconSegmentedControl<PreviewViewMode>(
            value: viewMode,
            onChanged: onViewModeChanged,
            onMutedSurface: true,
            segments: _viewModeSegments,
          ),
          const SizedBox(width: 8),
          IconSegmentedControl<Brightness>(
            value: previewBrightness,
            onChanged: onPreviewThemeChanged,
            onMutedSurface: true,
            segments: _brightnessSegments,
          ),
          const SizedBox(width: 8),
          // In desktop view, minimizing only hides the shell's toolbar and this
          // header stays — so the same spot has to offer the way back.
          SegmentedIconButton(
            icon: minimized ? LucideIcons.maximize : LucideIcons.minimize,
            tooltip: minimized ? 'Expand preview' : 'Minimize preview',
            onPressed: onToggleMinimized,
            onMutedSurface: true,
          ),
        ],
      ),
    );
  }
}

/// The floating control row under the frame in the compact window: view mode,
/// app theme, and the way back out.
class CompactControlBar extends StatelessWidget {
  const CompactControlBar({
    super.key,
    required this.viewMode,
    required this.previewBrightness,
    required this.onViewModeChanged,
    required this.onPreviewThemeChanged,
    required this.onExpand,
  });

  final PreviewViewMode viewMode;
  final Brightness previewBrightness;
  final ValueChanged<PreviewViewMode> onViewModeChanged;
  final ValueChanged<Brightness> onPreviewThemeChanged;
  final VoidCallback onExpand;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;

    return SizedBox(
      height: kCompactBarHeight,
      child: Center(
        // The window behind is transparent, so the bar carries its own opaque
        // surface — the desktop wallpaper is not a background anything can
        // count on being legible against.
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: scheme.background,
            borderRadius: theme.radii.lg,
            border: Border.all(color: scheme.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconSegmentedControl<PreviewViewMode>(
                value: viewMode,
                onChanged: onViewModeChanged,
                segments: _viewModeSegments,
              ),
              const SizedBox(width: 8),
              IconSegmentedControl<Brightness>(
                value: previewBrightness,
                onChanged: onPreviewThemeChanged,
                segments: _brightnessSegments,
              ),
              const SizedBox(width: 8),
              SegmentedIconButton(
                icon: LucideIcons.maximize,
                tooltip: 'Expand preview',
                onPressed: onExpand,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
