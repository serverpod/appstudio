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
