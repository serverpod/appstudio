import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../theme/app_theme.dart';

/// Icon-only segmented control styled like cloudui_flutter's account theme toggle.
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
    final scheme = ShadTheme.of(context).colorScheme;
    final trackColor = onMutedSurface ? scheme.background : scheme.muted;

    return Container(
      decoration: BoxDecoration(
        color: trackColor,
        borderRadius: BorderRadius.circular(6),
      ),
      padding: const EdgeInsets.all(2),
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

class _IconSegmentButton extends StatefulWidget {
  const _IconSegmentButton({
    required this.selected,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    required this.onMutedSurface,
    this.iconRotation = 0,
  });

  final bool selected;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool onMutedSurface;
  final double iconRotation;

  @override
  State<_IconSegmentButton> createState() => _IconSegmentButtonState();
}

class _IconSegmentButtonState extends State<_IconSegmentButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    final isActive = widget.selected;
    final activeColor = segmentedControlSelectedColor(
      scheme,
      ShadTheme.of(context).brightness,
      onMutedSurface: widget.onMutedSurface,
    );

    Widget icon = Icon(
      widget.icon,
      size: 16,
      color: isActive ? scheme.foreground : scheme.mutedForeground,
    );
    if (widget.iconRotation != 0) {
      icon = Transform.rotate(angle: widget.iconRotation, child: icon);
    }

    return ShadTooltip(
      builder: (context) => Text(widget.tooltip),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            decoration: BoxDecoration(
            color: isActive
                ? activeColor
                : _hovered
                ? segmentedControlHoverColor(
                    scheme,
                    onMutedSurface: widget.onMutedSurface,
                  )
                : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
              boxShadow: isActive
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.08),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
            padding: const EdgeInsets.all(4),
            child: icon,
          ),
        ),
      ),
    );
  }
}
