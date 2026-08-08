import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import 'segmented_control_theme.dart';

/// Icon-only segmented control styled like cloudui_flutter's account theme toggle.
///
/// Geometry and color come from the theme's tab tokens — the same strip/segment
/// treatment `ShadTabs` uses — so this follows the style preset and radius like
/// any built-in component.
///
/// On a default surface, the track uses [ShadColorScheme.muted] and the active
/// segment uses [ShadColorScheme.background]. Set [onMutedSurface] when the
/// control sits on a muted header/bar so the track/selection invert for contrast.
class IconSegmentedControl<T> extends StatelessWidget {
  const IconSegmentedControl({
    super.key,
    required this.value,
    required this.onChanged,
    required this.segments,
    this.onMutedSurface = false,
  });

  final T value;
  final ValueChanged<T> onChanged;
  final List<IconSegment<T>> segments;
  final bool onMutedSurface;

  @override
  Widget build(BuildContext context) {
    return SegmentTrack(
      onMutedSurface: onMutedSurface,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final segment in segments)
            _IconSegmentButton(
              selected: segment.value == value,
              tooltip: segment.tooltip,
              icon: segment.icon,
              iconRotation: segment.iconRotation,
              onPressed: () => onChanged(segment.value),
              onMutedSurface: onMutedSurface,
            ),
        ],
      ),
    );
  }
}

class IconSegment<T> {
  const IconSegment({
    required this.value,
    required this.tooltip,
    required this.icon,
    this.iconRotation = 0,
  });

  final T value;
  final String tooltip;
  final IconData icon;
  final double iconRotation;
}

/// Standalone icon button using the same track/segment styling as
/// [IconSegmentedControl].
class SegmentedIconButton extends StatelessWidget {
  const SegmentedIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.onMutedSurface = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool onMutedSurface;

  @override
  Widget build(BuildContext context) {
    return SegmentTrack(
      onMutedSurface: onMutedSurface,
      child: _IconSegmentButton(
        selected: false,
        tooltip: tooltip,
        icon: icon,
        onPressed: onPressed,
        onMutedSurface: onMutedSurface,
      ),
    );
  }
}

class _IconSegmentButton extends StatefulWidget {
  const _IconSegmentButton({
    required this.selected,
    required this.tooltip,
    required this.icon,
    required this.onMutedSurface,
    this.onPressed,
    this.iconRotation = 0,
  });

  final bool selected;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool onMutedSurface;
  final double iconRotation;

  @override
  State<_IconSegmentButton> createState() => _IconSegmentButtonState();
}

class _IconSegmentButtonState extends State<_IconSegmentButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final enabled = widget.onPressed != null;
    final isActive = widget.selected;

    Widget icon = Icon(
      widget.icon,
      size: 16,
      color: segmentForegroundColor(
        theme.colorScheme,
        selected: isActive,
        hovered: _hovered && enabled,
      ),
    );
    if (widget.iconRotation != 0) {
      icon = Transform.rotate(angle: widget.iconRotation, child: icon);
    }
    if (!enabled) {
      icon = Opacity(opacity: 0.4, child: icon);
    }

    return ShadTooltip(
      builder: (context) => Text(widget.tooltip),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: enabled ? (_) => setState(() => _hovered = true) : null,
        onExit: enabled ? (_) => setState(() => _hovered = false) : null,
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            decoration: segmentDecoration(
              theme,
              selected: isActive,
              onMutedSurface: widget.onMutedSurface,
            ),
            padding: const EdgeInsets.all(4),
            child: icon,
          ),
        ),
      ),
    );
  }
}
