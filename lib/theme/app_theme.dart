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

/// Headline face, bundled at Black (900) and no other weight.
///
/// It is the font shad's metrics were drawn for, so unlike [_kMacUiFont] it
/// needs no correction — see [_kWeightAxisRatio]. The static cut carries no
/// `wght` axis either, so a variation on a headline role would be ignored:
/// headlines set [FontWeight.w900] and nothing else.
const kHeadlineFont = 'Inter';

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
  // Headlines leave the UI font entirely, so they leave the correction behind
  // with it: [kHeadlineFont] ships one weight and shad's scale was drawn for
  // that typeface. Sizes, line heights and tracking stay shad's.
  TextStyle headline(TextStyle s) =>
      s.copyWith(fontFamily: kHeadlineFont, fontWeight: FontWeight.w900);
  return base.copyWith(
    h1Large: headline(base.h1Large),
    h1: headline(base.h1),
    h2: headline(base.h2),
    h3: headline(base.h3),
    h4: headline(base.h4),
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

/// Square hit area for a ghost icon button in the top toolbar.
const kToolbarIconButtonSize = 34.0;

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

/// Glass over the landing backdrop.
///
/// Fixed alphas rather than palette entries because these sit on a brand image
/// rather than on `background` — there is no token that describes them, and the
/// image does not change with the system's brightness. Same reasoning that has
/// the landing banner hardcode black.
///
/// Two surfaces, both white, differing only in how much of the backdrop they
/// let through. The action cards sit in the middle of the gradient and are
/// lifted off it; the recents panel sits at the floor and is thinner, so the
/// deepest part of the gradient still reads through it.
///
/// White throughout only because the backdrop is drawn rather than
/// photographed — see `_LandingBackground`. The image it replaced washed out to
/// pale pink at the bottom, where a white scrim lightens an already-light
/// surface, and the panel had to be black to survive it.
const kLandingCardSurface = Color(0x1FFFFFFF);
const kLandingPanelSurface = Color(0x14FFFFFF);
const kLandingPanelBorder = Color(0x24FFFFFF);
const _kLandingHairline = Color(0x2EFFFFFF);
const _kLandingHover = Color(0x1FFFFFFF);
const _kLandingMutedForeground = Color(0xC7FFFFFF);

/// Type set over the backdrop is white throughout; the second value is for the
/// text that should recede without picking up a hue, such as a project's path.
const kLandingSubduedForeground = Color(0xB3FFFFFF);

/// The landing actions. Pink rather than the app's brand blue, which is a poor
/// neighbour to the blues this gradient starts in.
const kLandingActionColor = Color(0xFFDB2777); // pink-600

/// The outer radius a [padding]-wide card needs for its border to look the same
/// thickness all the way round a child with [inner] corners.
///
/// Concentric, not equal: a card and its child sharing one radius leaves the
/// gap between them visibly fatter at the corners than along the edges.
BorderRadius concentricRadius(BorderRadius inner, double padding) =>
    BorderRadius.all(Radius.circular(inner.topLeft.x + padding));

/// The theme every pre-project screen uses, in both system brightnesses.
///
/// `LandingScaffold` paints one saturated brand image whatever the system is
/// set to, so following light mode there would put pale chrome and dark text on
/// a dark photograph. Dark is not a preference here, it is what the backdrop
/// is.
///
/// Everything with one obvious slot is folded into the *scheme* rather than
/// handed to each widget, so the screens on top keep reading `scheme.primary` /
/// `scheme.card` / `scheme.accent` like the rest of the app. The recents panel
/// is the exception: it is the second surface, and there is no token for that.
ShadThemeData buildLandingTheme() => _landingTheme;

/// Built once: unlike the app themes this is rebuilt on every frame of a
/// landing screen, and a fresh [ShadThemeData] each time would make every
/// descendant that depends on it rebuild too.
final _landingTheme = _buildTheme(
  Brightness.dark,
  darkColorScheme.copyWith(
    primary: kLandingActionColor,
    primaryForeground: Colors.white,
    ring: kLandingActionColor,
    card: kLandingCardSurface,
    cardForeground: Colors.white,
    accent: _kLandingHover,
    accentForeground: Colors.white,
    muted: kLandingCardSurface,
    mutedForeground: _kLandingMutedForeground,
    border: _kLandingHairline,
    input: _kLandingHairline,
    foreground: Colors.white,
  ),
);
