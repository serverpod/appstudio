import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

/// A reusable hoverable menu item for use inside [ShadPopover] panels.
class MenuItemTile extends StatefulWidget {
  const MenuItemTile({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.subtitle,
    this.reserveIconSpace = false,
  });

  final String label;
  final VoidCallback onTap;
  final IconData? icon;
  final String? subtitle;

  /// When true, always allocates the leading icon column so rows stay aligned
  /// even when [icon] is null (e.g. unchecked items next to a checkmark).
  final bool reserveIconSpace;

  @override
  State<MenuItemTile> createState() => _MenuItemTileState();
}

class _MenuItemTileState extends State<MenuItemTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final textTheme = theme.textTheme;
    final showIconSlot = widget.icon != null || widget.reserveIconSpace;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: _hovered ? theme.colorScheme.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            children: [
              if (showIconSlot) ...[
                SizedBox(
                  width: 14,
                  height: 14,
                  child: widget.icon != null
                      ? Icon(
                          widget.icon,
                          size: 14,
                          color: theme.colorScheme.mutedForeground,
                        )
                      : null,
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.label,
                      style: textTheme.small.copyWith(
                        color: theme.colorScheme.foreground,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (widget.subtitle != null)
                      Text(
                        widget.subtitle!,
                        style: textTheme.muted.copyWith(fontSize: 10),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
