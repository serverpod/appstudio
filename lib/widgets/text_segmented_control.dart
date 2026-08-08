import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import 'segmented_control_theme.dart';

/// Text segmented control styled like [IconSegmentedControl] — same tab tokens,
/// same track/selection pair.
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
    return SegmentTrack(
      onMutedSurface: onMutedSurface,
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
    final theme = ShadTheme.of(context);
    final isActive = widget.selected;
    final interactive = widget.onPressed != null;

    final child = Container(
      decoration: segmentDecoration(
        theme,
        selected: isActive,
        onMutedSurface: widget.onMutedSurface,
      ),
      padding: EdgeInsets.symmetric(
        horizontal: theme.style.tabPaddingX,
        vertical: theme.style.tabPaddingY,
      ),
      child: Text(
        widget.label,
        style: theme.style.label.apply(theme.textTheme.small).copyWith(
              color: segmentForegroundColor(
                theme.colorScheme,
                selected: isActive,
                hovered: interactive && _hovered,
              ),
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
