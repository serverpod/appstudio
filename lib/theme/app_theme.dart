import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.toolbarBackground,
    required this.paneHeaderBackground,
    required this.divider,
    required this.badgeBackground,
    required this.badgeForeground,
    required this.statusIdle,
    required this.statusStarting,
    required this.statusRunning,
    required this.statusReady,
    required this.statusDanger,
    required this.emptyStateMuted,
  });

  final Color toolbarBackground;
  final Color paneHeaderBackground;
  final Color divider;
  final Color badgeBackground;
  final Color badgeForeground;
  final Color statusIdle;
  final Color statusStarting;
  final Color statusRunning;
  final Color statusReady;
  final Color statusDanger;
  final Color emptyStateMuted;

  static const light = AppColors(
    toolbarBackground: Color(0xFFF4F6F8),
    paneHeaderBackground: Color(0xFFEEF1F4),
    divider: Color(0xFFD8DEE6),
    badgeBackground: Color(0xFFE2E8F0),
    badgeForeground: Color(0xFF334155),
    statusIdle: Color(0xFF64748B),
    statusStarting: Color(0xFFD97706),
    statusRunning: Color(0xFF0F766E),
    statusReady: Color(0xFF059669),
    statusDanger: Color(0xFFDC2626),
    emptyStateMuted: Color(0xFF64748B),
  );

  static const dark = AppColors(
    toolbarBackground: Color(0xFF1A1F26),
    paneHeaderBackground: Color(0xFF151A20),
    divider: Color(0xFF2A3340),
    badgeBackground: Color(0xFF243041),
    badgeForeground: Color(0xFFCBD5E1),
    statusIdle: Color(0xFF94A3B8),
    statusStarting: Color(0xFFFBBF24),
    statusRunning: Color(0xFF2DD4BF),
    statusReady: Color(0xFF34D399),
    statusDanger: Color(0xFFF87171),
    emptyStateMuted: Color(0xFF94A3B8),
  );

  @override
  AppColors copyWith({
    Color? toolbarBackground,
    Color? paneHeaderBackground,
    Color? divider,
    Color? badgeBackground,
    Color? badgeForeground,
    Color? statusIdle,
    Color? statusStarting,
    Color? statusRunning,
    Color? statusReady,
    Color? statusDanger,
    Color? emptyStateMuted,
  }) {
    return AppColors(
      toolbarBackground: toolbarBackground ?? this.toolbarBackground,
      paneHeaderBackground: paneHeaderBackground ?? this.paneHeaderBackground,
      divider: divider ?? this.divider,
      badgeBackground: badgeBackground ?? this.badgeBackground,
      badgeForeground: badgeForeground ?? this.badgeForeground,
      statusIdle: statusIdle ?? this.statusIdle,
      statusStarting: statusStarting ?? this.statusStarting,
      statusRunning: statusRunning ?? this.statusRunning,
      statusReady: statusReady ?? this.statusReady,
      statusDanger: statusDanger ?? this.statusDanger,
      emptyStateMuted: emptyStateMuted ?? this.emptyStateMuted,
    );
  }

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      toolbarBackground:
          Color.lerp(toolbarBackground, other.toolbarBackground, t)!,
      paneHeaderBackground:
          Color.lerp(paneHeaderBackground, other.paneHeaderBackground, t)!,
      divider: Color.lerp(divider, other.divider, t)!,
      badgeBackground: Color.lerp(badgeBackground, other.badgeBackground, t)!,
      badgeForeground: Color.lerp(badgeForeground, other.badgeForeground, t)!,
      statusIdle: Color.lerp(statusIdle, other.statusIdle, t)!,
      statusStarting: Color.lerp(statusStarting, other.statusStarting, t)!,
      statusRunning: Color.lerp(statusRunning, other.statusRunning, t)!,
      statusReady: Color.lerp(statusReady, other.statusReady, t)!,
      statusDanger: Color.lerp(statusDanger, other.statusDanger, t)!,
      emptyStateMuted: Color.lerp(emptyStateMuted, other.emptyStateMuted, t)!,
    );
  }
}

abstract final class AppTheme {
  static const _accent = Color(0xFF0F766E);
  static const _accentDark = Color(0xFF2DD4BF);

  static TextTheme _textTheme(Brightness brightness) {
    final base = GoogleFonts.ibmPlexSansTextTheme();
    final color =
        brightness == Brightness.light ? const Color(0xFF0F172A) : const Color(0xFFE2E8F0);
    return base.apply(bodyColor: color, displayColor: color);
  }

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _accent,
      brightness: Brightness.light,
      primary: _accent,
      surface: const Color(0xFFF8FAFC),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFFF8FAFC),
      textTheme: _textTheme(Brightness.light),
      dividerColor: AppColors.light.divider,
      extensions: const [AppColors.light],
      iconTheme: const IconThemeData(size: 18, color: Color(0xFF334155)),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: GoogleFonts.ibmPlexSans(
          color: Colors.white,
          fontSize: 12,
        ),
      ),
    );
  }

  static ThemeData dark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: _accentDark,
      brightness: Brightness.dark,
      primary: _accentDark,
      surface: const Color(0xFF0F1419),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: const Color(0xFF0F1419),
      textTheme: _textTheme(Brightness.dark),
      dividerColor: AppColors.dark.divider,
      extensions: const [AppColors.dark],
      iconTheme: const IconThemeData(size: 18, color: Color(0xFFCBD5E1)),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(
          color: const Color(0xFF334155),
          borderRadius: BorderRadius.circular(6),
        ),
        textStyle: GoogleFonts.ibmPlexSans(
          color: Colors.white,
          fontSize: 12,
        ),
      ),
    );
  }
}
