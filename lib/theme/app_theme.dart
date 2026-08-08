import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

/// Serverpod brand blue. It is the theme's *accent* over shadcn's Slate base
/// palette — see [_scheme], which derives `primary`, `ring` and `selection`
/// from it rather than spelling each one out.
const Color kBrandBlue = Color(0xFF1295F0);

/// macOS system UI font (SF Pro on modern macOS).
const _kMacUiFont = '.AppleSystemUIFont';

/// macOS monospace font for terminal output.
const kMacMonoFont = 'Menlo';

/// shadcn's "Medium" radius preset. Its `--radius` is 10; components use
/// `--radius-md`, which is `--radius * 0.8`. Everything else on the scale
/// derives from this one value.
const kThemeRadius = BorderRadius.all(Radius.circular(8));

/// Shared height for pane headers (preview bar, terminal tabs, etc.).
///
/// The segmented controls in these bars are 30px — the height the style
/// preset's tab tokens give them — so this is sized to clear them by 5px top
/// and bottom. Shrinking it squeezes that gap rather than the controls, which
/// keep their own inset; retune here, not in the controls.
const kPaneHeaderHeight = 40.0;

/// Standard 1px divider stroke for pane chrome and toolbars.
const kDividerWidth = 1.0;

/// Drag hit area for the workspace split handle (visual line stays [kDividerWidth]).
const kSplitHandleWidth = 6.0;

/// Left (agent + logs) panel as a fraction of workspace width when resizing.
const kWorkspaceMinSplitRatio = 0.375; // 150% of the former 0.25 minimum
const kWorkspaceMaxSplitRatio = 0.70;

BorderSide paneBorderSide(Color color) =>
    BorderSide(color: color, width: kDividerWidth);

/// Status hues shadcn has no token for.
///
/// Failure is *not* here: that is `colorScheme.destructive`, which shad already
/// defines and uses as a foreground itself. Success and warning ride in the
/// scheme's `custom` map so they lerp and switch with every other token; read
/// them through [AppColorScheme].
///
/// One value per status covers both the dot and its label — a status mark and
/// the text beside it should share a hue — so each is picked to be legible on
/// that brightness's background.
const _kLightStatus = <String, Color>{
  'success': Color(0xFF15803D), // green-700
  'warning': Color(0xFFB45309), // amber-700
};

const _kDarkStatus = <String, Color>{
  'success': Color(0xFF86EFAC), // green-300
  'warning': Color(0xFFF59E0B), // amber-500
};

/// The status colors from [_kLightStatus] / [_kDarkStatus], read like any
/// built-in slot.
extension AppColorScheme on ShadColorScheme {
  Color get success => custom['success']!;

  Color get warning => custom['warning']!;
}

ShadColorScheme _scheme(Brightness brightness) {
  final base = brightness == Brightness.light
      ? ShadSlateColorScheme.light(custom: _kLightStatus)
      : ShadSlateColorScheme.dark(custom: _kDarkStatus);
  return base.applyAccent(kBrandBlue);
}

final lightColorScheme = _scheme(Brightness.light);
final darkColorScheme = _scheme(Brightness.dark);

/// Shad's destructive variant is a soft tint (`bg-destructive/10`), which
/// reads as disabled when it is the affirmative button of a confirm dialog —
/// see the Uninstall dialog. Restore a solid fill so the destructive action
/// carries the weight of the choice it commits.
ShadButtonTheme _destructiveButtonTheme(ShadColorScheme scheme) =>
    ShadButtonTheme(
      backgroundColor: scheme.destructive,
      hoverBackgroundColor: scheme.destructive.withValues(alpha: 0.9),
      foregroundColor: scheme.destructiveForeground,
      hoverForegroundColor: scheme.destructiveForeground,
    );

ShadThemeData _buildTheme(Brightness brightness, ShadColorScheme scheme) =>
    ShadThemeData(
      brightness: brightness,
      colorScheme: scheme,
      style: ShadStyleTokens.nova,
      radius: kThemeRadius,
      textTheme: ShadTextTheme(family: _kMacUiFont),
      // Styling is shad's; only the hover delay is ours — the default fires
      // fast enough to flash tooltips while the pointer crosses a toolbar.
      tooltipTheme: const ShadTooltipTheme(
        waitDuration: Duration(milliseconds: 700),
      ),
      destructiveButtonTheme: _destructiveButtonTheme(scheme),
    );

ShadThemeData buildLightTheme() =>
    _buildTheme(Brightness.light, lightColorScheme);

ShadThemeData buildDarkTheme() => _buildTheme(Brightness.dark, darkColorScheme);
