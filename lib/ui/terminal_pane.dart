import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:xterm/xterm.dart';

import '../agent/agent_controller.dart';
import '../terminal/studio_terminal.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/text_segmented_control.dart';
import 'agent/agent_pane.dart';

enum _TerminalTab { agent, serverLogs }

class TerminalPane extends StatefulWidget {
  const TerminalPane({
    super.key,
    required this.studioTerminal,
    required this.agent,
    this.onOpenSettings,
  });

  final StudioTerminal studioTerminal;
  final AgentController agent;
  final VoidCallback? onOpenSettings;

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
  _TerminalTab _selectedTab = _TerminalTab.agent;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final xtermTheme = TerminalPane.terminalTheme(theme);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: kPaneHeaderHeight,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: scheme.muted,
            border: Border(bottom: paneBorderSide(scheme.border)),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextSegmentedControl<_TerminalTab>(
              value: _selectedTab,
              onChanged: (tab) => setState(() => _selectedTab = tab),
              onMutedSurface: true,
              segments: const [
                TextSegment(value: _TerminalTab.agent, label: 'Agent'),
                TextSegment(
                  value: _TerminalTab.serverLogs,
                  label: 'Server logs',
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: scheme.background,
            child: switch (_selectedTab) {
              _TerminalTab.agent => AgentPane(
                  controller: widget.agent,
                  onOpenSettings: widget.onOpenSettings,
                ),
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
