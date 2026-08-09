import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../theme/app_theme.dart';

/// The app's themes, built once for the whole preview session rather than per
/// preview. See [warmThemes] for why *when* they are built matters.
final _lightTheme = buildLightTheme();
final _darkTheme = buildDarkTheme();

/// Builds both themes now, from wherever the caller is standing — and the
/// caller must be standing somewhere shallow. **Every preview fails without
/// this**, and the failure looks nothing like its cause.
///
/// Constructing a [ShadThemeData] resolves every component theme up front, and
/// one of them (`primaryToastTheme`) reads `LucideIcons.x`. That is the first
/// touch of `lucide_icons_flutter`, a single generated library with ~27,900
/// `static const IconData` fields, so DDC has to link the whole thing right
/// there. On the web — the only device the preview scaffold supports — that
/// link overflows the JS stack if it happens deep in a widget build, and the
/// scaffold reports it per preview as
/// `Failed to initialize widget tree: Stack Overflow`, pointing at shad's
/// theme code with no hint that stack depth is the problem.
///
/// Linking the same library from a shallow frame is fine, and it only has to
/// happen once, so the fix is to get there first: `BrightnessPreview.transform`
/// calls this, and the scaffold calls `transform()` from `main()`. Anything
/// that builds a theme from inside a build without warming first brings the
/// overflow back.
void warmThemes() {
  _lightTheme;
  _darkTheme;
}

/// Wraps a preview in the app's real theme.
///
/// Previews render outside `main.dart`, so without this they would show
/// Material defaults and tell you nothing useful about spacing or colour.
///
/// Brightness is deliberately not a parameter. `ShadApp` resolves
/// [ThemeMode.system] against [MediaQuery.platformBrightnessOf], which is
/// exactly what the preview scaffold overrides — so `brightness:` on the
/// annotation *and* the scaffold's own light/dark toggle both drive this for
/// free. A `dark` flag of our own would only be able to fight them.
Widget previewShell(Widget child) => ShadApp(
  debugShowCheckedModeBanner: false,
  theme: _lightTheme,
  darkTheme: _darkTheme,
  home: Scaffold(body: Center(child: child)),
);
