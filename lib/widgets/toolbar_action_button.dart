import 'package:flutter/widgets.dart';
import 'package:shad/shad.dart';

import '../theme/app_theme.dart';

/// Outline icon button for the top toolbar, with a spinner in the icon's place
/// while the action is in flight.
///
/// Shared by Hot Restart and Full Restart so the two cannot drift in size,
/// spinner size or disabled behaviour — they sit next to each other, and a 2px
/// difference between them is visible.
class ToolbarActionButton extends StatelessWidget {
  const ToolbarActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.busy = false,
    this.failed = false,
  });

  /// Not drawn — the buttons are icon-only — but carried through as the
  /// accessibility label, which is otherwise the icon glyph and nothing.
  final String label;

  final IconData icon;

  /// Always shown, including when disabled. With no text on the button this is
  /// the only place it can say what it does, or why it cannot.
  final String tooltip;

  /// Null disables the button.
  final VoidCallback? onPressed;

  /// Swaps the icon for a spinner. Does not disable on its own; a busy action
  /// should also pass a null [onPressed].
  final bool busy;

  /// Tints the icon destructive — for an action that ran and failed, as opposed
  /// to one that was never available.
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;

    return ShadTooltip(
      builder: (context) => Text(tooltip),
      // Wrapping the button rather than being wrapped by it. A disabled
      // `ShadButton` puts its content behind an `AbsorbPointer`, which eats the
      // hover `ShadTooltip` listens for, so the tooltip explaining *why* it is
      // disabled would never appear. This detector sits outside that.
      child: ShadGestureDetector(
        child: ShadIconButton.outline(
          semanticLabel: label,
          // `enabled` is what drives the dimming — a null handler on its own
          // leaves the button inert but looking live.
          enabled: onPressed != null,
          onPressed: onPressed,
          width: kToolbarIconButtonSize,
          height: kToolbarIconButtonSize,
          icon: busy
              ? const ShadSpinner(size: 14)
              : Icon(
                  icon,
                  size: 16,
                  color: failed ? scheme.destructive : null,
                ),
        ),
      ),
    );
  }
}
