/// Widgetbook for App Studio: every screen and dialog, in every state, in both
/// themes — for reviewing copy and layout without reaching each state by hand.
///
/// Run with `make widgetbook`. It is a second entry point into this package
/// rather than an app of its own, so it runs in App Studio's own macOS runner
/// with the same fonts, assets and plugins.
library;

import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import 'catalog.dart';
import 'host.dart';

void main() => runApp(const AppStudioWidgetbook());

class AppStudioWidgetbook extends StatelessWidget {
  const AppStudioWidgetbook({super.key});

  @override
  Widget build(BuildContext context) {
    return Widgetbook(
      directories: catalog,
      // The host below brings the app's own ShadApp; a second app around it
      // would only get in the way.
      appBuilder: (context, child) => child,
      addons: [
        ThemeAddon<Brightness>(
          themes: const [
            WidgetbookTheme(name: 'Light', data: Brightness.light),
            WidgetbookTheme(name: 'Dark', data: Brightness.dark),
          ],
          themeBuilder: (context, brightness, child) => UseCaseHost(
            // Keyed by the whole URL, use case and theme both: a fresh
            // navigator per view, so a dialog pushed for one use case can never
            // be left on screen over the next.
            key: ValueKey(WidgetbookState.of(context).uri.toString()),
            brightness: brightness,
            child: child,
          ),
        ),
      ],
    );
  }
}
