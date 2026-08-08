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

/// How far our font's weight axis travels compared with the one shad's
/// metrics were drawn for.
///
/// Measured, not guessed: laying out the same string at 14px across the axis,
/// Inter (shad's default) widens ~1.65px per 100 weight units while
/// `.AppleSystemUIFont` widens ~3.17px. Both axes resolve correctly and
/// neither synthesises bold — SF's is simply about twice as hot, so an
/// uncorrected `w500` lands where Inter's `w600` would and the whole UI reads
/// a step heavy.
const _kWeightAxisRatio = 1.65 / 3.17;

/// A `wght` variation carrying the appearance [weight] has in shad's font.
///
/// Expressed as a variation rather than a [FontWeight] for two reasons: the
/// corrected values are not multiples of 100, which [FontWeight] cannot
/// represent, and a variation overrides an inherited `fontWeight` at render
/// time — the only way to reach a weight a component hardcodes.
///
/// Where the axis is unavailable the inherited `fontWeight` simply stands, so
/// the failure mode is shad's uncorrected look rather than a broken one.
TextStyle correctedWeight(FontWeight weight) => TextStyle(
  fontVariations: [
    FontVariation('wght', 400 + (weight.value - 400) * _kWeightAxisRatio),
  ],
);

/// shad's `w500` and `w600`, corrected.
final kWeightMedium = correctedWeight(FontWeight.w500);
final kWeightSemibold = correctedWeight(FontWeight.w600);

/// Emphasis for text rendered in the UI font.
///
/// Use these instead of `copyWith(fontWeight: …)`. Every role in
/// [_kMacTextTheme] carries a `wght` variation and a variation beats a
/// `fontWeight`, so a raw weight is silently ignored — it would leave the text
/// at its role's weight rather than the emphasis it asked for.
extension UiTextWeight on TextStyle {
  /// shad's `w500`.
  TextStyle get medium => merge(kWeightMedium);

  /// shad's `w600`.
  TextStyle get semibold => merge(kWeightSemibold);
}

/// shad's type scale with every role's weight moved onto our font's axis.
///
/// Every role carries an explicit variation, including the `w400` ones, so no
/// text in the app can render on the uncorrected scale — a component that
/// copies a role and bumps `fontWeight` (`ShadCheckbox` does exactly this to
/// its label) lands on the corrected weight instead of a too-heavy one. The
/// cost is that such a component loses its *emphasis*, so where that emphasis
/// matters the call site restores it with [kWeightMedium].
ShadTextTheme _buildTextTheme() {
  final base = ShadTextTheme(family: _kMacUiFont);
  TextStyle fix(TextStyle s) =>
      s.merge(correctedWeight(s.fontWeight ?? FontWeight.w400));
  return base.copyWith(
    h1Large: fix(base.h1Large),
    h1: fix(base.h1),
    h2: fix(base.h2),
    h3: fix(base.h3),
    h4: fix(base.h4),
    p: fix(base.p),
    blockquote: fix(base.blockquote),
    table: fix(base.table),
    list: fix(base.list),
    lead: fix(base.lead),
    large: fix(base.large),
    small: fix(base.small),
    muted: fix(base.muted),
  );
}

final _kMacTextTheme = _buildTextTheme();

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

/// A soft green badge for installed or host-reused tools — same tint pattern
/// as shad's destructive badge (`bg-destructive/10 text-destructive`).
ShadBadge appSuccessBadge(ShadThemeData theme, {required Widget child}) =>
    _washBadge(theme, theme.colorScheme.success, child);

/// The amber counterpart, for a tool that is not there yet.
///
/// Warning rather than destructive: nothing is broken and nothing was lost —
/// there is a button on this very screen that fixes it.
ShadBadge appWarningBadge(ShadThemeData theme, {required Widget child}) =>
    _washBadge(theme, theme.colorScheme.warning, child);

ShadBadge _washBadge(ShadThemeData theme, Color color, Widget child) {
  final wash = color.withValues(
    alpha: theme.brightness == Brightness.dark ? 0.2 : 0.1,
  );
  return ShadBadge(
    foregroundColor: color,
    backgroundColor: wash,
    hoverBackgroundColor: wash,
    child: child,
  );
}

ShadColorScheme _scheme(Brightness brightness) {
  final base = brightness == Brightness.light
      ? ShadSlateColorScheme.light(custom: _kLightStatus)
      : ShadSlateColorScheme.dark(custom: _kDarkStatus);
  return base.applyAccent(kBrandBlue);
}

final lightColorScheme = _scheme(Brightness.light);
final darkColorScheme = _scheme(Brightness.dark);

ShadThemeData _buildTheme(Brightness brightness, ShadColorScheme scheme) =>
    ShadThemeData(
      brightness: brightness,
      colorScheme: scheme,
      style: ShadStyleTokens.nova,
      radius: kThemeRadius,
      textTheme: _kMacTextTheme,
      // Styling is shad's; only the hover delay is ours — the default fires
      // fast enough to flash tooltips while the pointer crosses a toolbar.
      tooltipTheme: const ShadTooltipTheme(
        waitDuration: Duration(milliseconds: 700),
      ),
      cardTheme: _kCardTheme,
    );

/// Cards, tightened for use as rows rather than as standalone panels.
///
/// Nova gives a card `xl` corners (14) and 16 of padding, which suits a page
/// with a card or two on it. Ours stack as list rows next to controls, so the
/// radius drops to `lg` (10) — the step the button and select triggers use, so
/// a card no longer looks rounder than the dropdown beside it — and the padding
/// halves.
final _kCardTheme = ShadCardTheme(
  radius: ShadRadii(kThemeRadius).lg,
  padding: const EdgeInsets.all(8),
);

ShadThemeData buildLightTheme() =>
    _buildTheme(Brightness.light, lightColorScheme);

ShadThemeData buildDarkTheme() => _buildTheme(Brightness.dark, darkColorScheme);
