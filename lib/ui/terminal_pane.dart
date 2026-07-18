import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:xterm/xterm.dart';

import '../terminal/studio_terminal.dart';
import '../theme/app_theme.dart';

class TerminalPane extends StatelessWidget {
  const TerminalPane({super.key, required this.studioTerminal});

  final StudioTerminal studioTerminal;

  static final TerminalTheme paperTheme = TerminalTheme(
    cursor: const Color(0xFF0F172A),
    selection: const Color(0x660F766E),
    foreground: const Color(0xFF0F172A),
    background: const Color(0xFFEEF1F5),
    black: const Color(0xFF0F172A),
    red: const Color(0xFFDC2626),
    green: const Color(0xFF059669),
    yellow: const Color(0xFFD97706),
    blue: const Color(0xFF2563EB),
    magenta: const Color(0xFF9333EA),
    cyan: const Color(0xFF0F766E),
    white: const Color(0xFF334155),
    brightBlack: const Color(0xFF64748B),
    brightRed: const Color(0xFFEF4444),
    brightGreen: const Color(0xFF10B981),
    brightYellow: const Color(0xFFF59E0B),
    brightBlue: const Color(0xFF3B82F6),
    brightMagenta: const Color(0xFFA855F7),
    brightCyan: const Color(0xFF14B8A6),
    brightWhite: const Color(0xFF0F172A),
    searchHitBackground: const Color(0x66FBBF24),
    searchHitBackgroundCurrent: const Color(0x99F59E0B),
    searchHitForeground: const Color(0xFF0F172A),
  );

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: colors.paneHeaderBackground,
            border: Border(
              bottom: BorderSide(color: colors.divider, width: 1),
            ),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.terminal, size: 14, color: colors.statusIdle),
              const SizedBox(width: 8),
              Text(
                'Terminal',
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: paperTheme.background,
            child: TerminalView(
              studioTerminal.terminal,
              theme: paperTheme,
              textStyle: TerminalStyle(
                fontSize: 13,
                fontFamily: GoogleFonts.ibmPlexMono().fontFamily!,
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
