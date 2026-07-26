import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

// Brand palette — matches Serverpod Cloud / cloudui_flutter.
const Color kBrandBlue = Color(0xFF1295F0);
const Color kBrandBlueDark = Color(0xFF0880D8);
const Color kBrandBlueForeground = Colors.white;
const Color kBrandBlueSelection = Color(0xFFC2E0FF);

/// macOS system UI font (SF Pro on modern macOS).
const _kMacUiFont = '.AppleSystemUIFont';

/// macOS monospace font for terminal output.
const kMacMonoFont = 'Menlo';

/// Shared height for pane headers (preview bar, terminal tabs, etc.).
const kPaneHeaderHeight = 36.0;

/// Standard 1px divider stroke for pane chrome and toolbars.
const kDividerWidth = 1.0;

/// Drag hit area for the workspace split handle (visual line stays [kDividerWidth]).
const kSplitHandleWidth = 6.0;

/// Left (agent + logs) panel as a fraction of workspace width when resizing.
const kWorkspaceMinSplitRatio = 0.375; // 150% of the former 0.25 minimum
const kWorkspaceMaxSplitRatio = 0.70;

BorderSide paneBorderSide(Color color) =>
    BorderSide(color: color, width: kDividerWidth);

/// Subtle hover fill for segmented control segments (distinct from selection).
Color segmentedControlHoverColor(
  ShadColorScheme scheme, {
  required bool onMutedSurface,
}) {
  final track = onMutedSurface ? scheme.background : scheme.muted;
  return Color.alphaBlend(
    scheme.foreground.withValues(alpha: 0.06),
    track,
  );
}

/// Fill for the selected segment in a segmented control.
Color segmentedControlSelectedColor(
  ShadColorScheme scheme,
  Brightness brightness, {
  required bool onMutedSurface,
}) {
  if (onMutedSurface) {
    // On pane headers (muted bar + white track), light-mode muted is too close to white.
    return brightness == Brightness.light ? scheme.border : scheme.muted;
  }
  return scheme.background;
}

const ShadSlateColorScheme lightColorScheme = ShadSlateColorScheme.light(
  primary: kBrandBlue,
  primaryForeground: kBrandBlueForeground,
  ring: kBrandBlue,
  selection: kBrandBlueSelection,
);

const ShadSlateColorScheme darkColorScheme = ShadSlateColorScheme.dark(
  primary: kBrandBlue,
  primaryForeground: kBrandBlueForeground,
  ring: kBrandBlue,
  selection: kBrandBlueSelection,
  // Default dark slate sets border == muted (#1e293b), which hides dividers.
  border: Color(0xFF334155),
  input: Color(0xFF334155),
);

const _kTooltipTheme = ShadTooltipTheme(
  waitDuration: Duration(milliseconds: 700),
  padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
);

final _kMacTextTheme = ShadTextTheme(family: _kMacUiFont);

ShadThemeData buildLightTheme() => ShadThemeData(
      brightness: Brightness.light,
      colorScheme: lightColorScheme,
      textTheme: _kMacTextTheme,
      tooltipTheme: _kTooltipTheme,
    );

ShadThemeData buildDarkTheme() => ShadThemeData(
      brightness: Brightness.dark,
      colorScheme: darkColorScheme,
      textTheme: _kMacTextTheme,
      tooltipTheme: _kTooltipTheme,
    );
