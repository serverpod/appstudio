import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:xterm/xterm.dart';

import '../terminal/studio_terminal.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

enum _TerminalTab { agent, serverLogs }

class TerminalPane extends StatefulWidget {
  const TerminalPane({super.key, required this.studioTerminal});

  final StudioTerminal studioTerminal;

  static TerminalTheme terminalTheme(ShadThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    if (isDark) {
      return TerminalTheme(
        cursor: theme.colorScheme.foreground,
        selection: theme.colorScheme.selection.withValues(alpha: 0.35),
        foreground: theme.colorScheme.foreground,
        background: theme.colorScheme.background,
        black: const Color(0xFF1E293B),
        red: AppColors.errorRed,
        green: AppColors.successDot,
        yellow: AppColors.warningAmber,
        blue: kBrandBlue,
        magenta: const Color(0xFFA855F7),
        cyan: const Color(0xFF14B8A6),
        white: theme.colorScheme.foreground,
        brightBlack: theme.colorScheme.mutedForeground,
        brightRed: const Color(0xFFFCA5A5),
        brightGreen: AppColors.successTextDark,
        brightYellow: AppColors.warningTextDark,
        brightBlue: const Color(0xFF93C5FD),
        brightMagenta: const Color(0xFFC4B5FD),
        brightCyan: const Color(0xFF5EEAD4),
        brightWhite: theme.colorScheme.foreground,
        searchHitBackground: const Color(0x66FBBF24),
        searchHitBackgroundCurrent: const Color(0x99F59E0B),
        searchHitForeground: theme.colorScheme.foreground,
      );
    }

    return TerminalTheme(
      cursor: theme.colorScheme.foreground,
      selection: theme.colorScheme.selection.withValues(alpha: 0.35),
      foreground: theme.colorScheme.foreground,
      background: theme.colorScheme.background,
      black: const Color(0xFF0F172A),
      red: AppColors.errorRed,
      green: AppColors.successDot,
      yellow: AppColors.warningAmber,
      blue: kBrandBlue,
      magenta: const Color(0xFF9333EA),
      cyan: const Color(0xFF0F766E),
      white: const Color(0xFF334155),
      brightBlack: theme.colorScheme.mutedForeground,
      brightRed: const Color(0xFFEF4444),
      brightGreen: const Color(0xFF10B981),
      brightYellow: const Color(0xFFF59E0B),
      brightBlue: const Color(0xFF3B82F6),
      brightMagenta: const Color(0xFFA855F7),
      brightCyan: const Color(0xFF14B8A6),
      brightWhite: theme.colorScheme.foreground,
      searchHitBackground: const Color(0x66FBBF24),
      searchHitBackgroundCurrent: const Color(0x99F59E0B),
      searchHitForeground: theme.colorScheme.foreground,
    );
  }

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  _TerminalTab _selectedTab = _TerminalTab.serverLogs;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final xtermTheme = TerminalPane.terminalTheme(theme);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TerminalTabBar(
          selected: _selectedTab,
          onSelected: (tab) => setState(() => _selectedTab = tab),
        ),
        Expanded(
          child: ColoredBox(
            color: scheme.background,
            child: switch (_selectedTab) {
              _TerminalTab.agent => const SizedBox.expand(),
              _TerminalTab.serverLogs => TerminalView(
                  widget.studioTerminal.terminal,
                  theme: xtermTheme,
                  textStyle: TerminalStyle(
                    fontSize: 13,
                    fontFamily: kMacMonoFont,
                  ),
                  padding: const EdgeInsets.all(8),
                  autofocus: true,
                  hardwareKeyboardOnly: true,
                ),
            },
          ),
        ),
      ],
    );
  }
}

/// VS Code–style panel tabs: active tab matches content and covers the strip divider.
class _TerminalTabBar extends StatelessWidget {
  const _TerminalTabBar({
    required this.selected,
    required this.onSelected,
  });

  final _TerminalTab selected;
  final ValueChanged<_TerminalTab> onSelected;

  static const _height = kPaneHeaderHeight;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;

    return SizedBox(
      height: _height,
      child: Stack(
        clipBehavior: Clip.none,
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.muted,
              border: Border(bottom: paneBorderSide(scheme.border)),
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _TerminalTabItem(
                label: 'Agent',
                selected: selected == _TerminalTab.agent,
                onTap: () => onSelected(_TerminalTab.agent),
                showRightBorder: true,
              ),
              _TerminalTabItem(
                label: 'Server logs',
                selected: selected == _TerminalTab.serverLogs,
                onTap: () => onSelected(_TerminalTab.serverLogs),
                showRightBorder: false,
              ),
              const Spacer(),
            ],
          ),
        ],
      ),
    );
  }
}

class _TerminalTabItem extends StatefulWidget {
  const _TerminalTabItem({
    required this.label,
    required this.selected,
    required this.onTap,
    required this.showRightBorder,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool showRightBorder;

  @override
  State<_TerminalTabItem> createState() => _TerminalTabItemState();
}

class _TerminalTabItemState extends State<_TerminalTabItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    final background = widget.selected
        ? scheme.background
        : _hovered
            ? scheme.accent.withValues(alpha: 0.55)
            : Colors.transparent;

    final textColor = widget.selected
        ? scheme.foreground
        : scheme.mutedForeground;

    final tab = Container(
      height: widget.selected
          ? _TerminalTabBar._height + 1
          : _TerminalTabBar._height,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: background,
        border: Border(
          right: widget.showRightBorder && !widget.selected
              ? paneBorderSide(scheme.border)
              : BorderSide.none,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        widget.label,
        style: textTheme.small.copyWith(
          color: textColor,
          fontWeight: widget.selected ? FontWeight.w500 : FontWeight.w400,
        ),
      ),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: widget.selected
            ? Transform.translate(offset: const Offset(0, 1), child: tab)
            : tab,
      ),
    );
  }
}
