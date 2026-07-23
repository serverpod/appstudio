import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:xterm/xterm.dart';

import '../terminal/studio_terminal.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

class TerminalPane extends StatelessWidget {
  const TerminalPane({super.key, required this.studioTerminal});

  final StudioTerminal studioTerminal;

  static TerminalTheme terminalTheme(ShadThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    if (isDark) {
      return TerminalTheme(
        cursor: theme.colorScheme.foreground,
        selection: theme.colorScheme.selection.withValues(alpha: 0.35),
        foreground: theme.colorScheme.foreground,
        background: theme.colorScheme.muted,
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
      background: theme.colorScheme.muted,
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
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final xtermTheme = terminalTheme(theme);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: scheme.muted,
            border: Border(bottom: BorderSide(color: scheme.border)),
          ),
          child: Row(
            children: [
              Icon(
                LucideIcons.terminal,
                size: 14,
                color: scheme.mutedForeground,
              ),
              const SizedBox(width: 8),
              Text(
                'Terminal',
                style: theme.textTheme.small.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: xtermTheme.background,
            child: TerminalView(
              studioTerminal.terminal,
              theme: xtermTheme,
              textStyle: TerminalStyle(
                fontSize: 13,
                fontFamily: kMacMonoFont,
              ),
              padding: const EdgeInsets.all(8),
              autofocus: true,
              hardwareKeyboardOnly: true,
            ),
          ),
        ),
      ],
    );
  }
}
