import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../theme/app_theme.dart';

/// Text segmented control styled like [IconSegmentedControl].
class TextSegmentedControl<T> extends StatelessWidget {
  const TextSegmentedControl({
    super.key,
    required this.value,
    required this.onChanged,
    required this.segments,
    this.onMutedSurface = false,
    this.interactive = true,
  });

  final T value;
  final ValueChanged<T> onChanged;
  final List<TextSegment<T>> segments;
  final bool onMutedSurface;
  final bool interactive;

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
            _TextSegmentButton(
              selected: segment.value == value,
              label: segment.label,
              onPressed: interactive ? () => onChanged(segment.value) : null,
              onMutedSurface: onMutedSurface,
            ),
        ],
      ),
    );
  }
}

class TextSegment<T> {
  const TextSegment({
    required this.value,
    required this.label,
  });

  final T value;
  final String label;
}

class _TextSegmentButton extends StatefulWidget {
  const _TextSegmentButton({
    required this.selected,
    required this.label,
    required this.onPressed,
    required this.onMutedSurface,
  });

  final bool selected;
  final String label;
  final VoidCallback? onPressed;
  final bool onMutedSurface;

  @override
  State<_TextSegmentButton> createState() => _TextSegmentButtonState();
}

class _TextSegmentButtonState extends State<_TextSegmentButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    final textTheme = ShadTheme.of(context).textTheme;
    final isActive = widget.selected;
    final activeColor = segmentedControlSelectedColor(
      scheme,
      ShadTheme.of(context).brightness,
      onMutedSurface: widget.onMutedSurface,
    );
    final interactive = widget.onPressed != null;

    final child = Container(
      decoration: BoxDecoration(
        color: isActive
            ? activeColor
            : interactive && _hovered
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
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Text(
        widget.label,
        style: textTheme.small.copyWith(
          color: isActive ? scheme.foreground : scheme.mutedForeground,
          fontWeight: isActive ? FontWeight.w500 : FontWeight.w400,
        ),
      ),
    );

    if (!interactive) return child;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: child,
      ),
    );
  }
}
