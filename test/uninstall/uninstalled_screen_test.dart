import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/uninstall/uninstalled_screen.dart';
import 'package:appstudio/uninstall/uninstall_result.dart';

/// Colour actually painted for [text], after the theme it sits in.
Color? _colorOf(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style?.color;

void main() {
  testWidgets('sets every colour, in either app brightness', (tester) async {
    // The screen is on the landing backdrop, which is dark in both. A text
    // role with no colour of its own falls through to the `DefaultTextStyle`
    // `ShadApp` installs from the *app* theme — which is how black text ends
    // up on the gradient in light mode.
    for (final appTheme in [buildLightTheme(), buildDarkTheme()]) {
      await tester.pumpWidget(
        ShadApp(
          theme: appTheme,
          home: const UninstalledScreen(result: UninstallResult(failures: [])),
        ),
      );
      await tester.pump();

      expect(
        _colorOf(tester, 'App Studio has been uninstalled'),
        Colors.white,
      );
      expect(
        _colorOf(
          tester,
          'All supporting files have been deleted. You can now safely move '
          'App Studio to the Trash.',
        ),
        isNotNull,
      );
    }
  });

  testWidgets('names the steps that failed', (tester) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: const UninstalledScreen(
          result: UninstallResult(failures: ['Could not clear preferences']),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.text('App Studio has been mostly uninstalled'),
      findsOneWidget,
    );
    expect(find.text('• Could not clear preferences'), findsOneWidget);
    expect(
      _colorOf(tester, '• Could not clear preferences'),
      isNotNull,
    );
  });
}
