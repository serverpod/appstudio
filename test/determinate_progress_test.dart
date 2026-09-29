import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/widgets/determinate_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

void main() {
  testWidgets('survives switching between determinate and indeterminate, '
      'more than once', (tester) async {
    // An install with the Command Line Tools in it goes indeterminate (Apple's
    // installer), determinate (the download), indeterminate (verifying).
    // ShadProgress on its own asserts on the second switch to indeterminate.
    Future<void> show(double? fraction) async {
      await tester.pumpWidget(
        ShadApp(
          theme: buildLightTheme(),
          home: Scaffold(body: DeterminateProgress(fraction: fraction)),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }

    for (final fraction in [null, 0.4, null, 0.8, null]) {
      await show(fraction);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a reserved caption line keeps its height while empty',
      (tester) async {
    // An install moves between steps with a caption and steps without one;
    // the dialog around the bar must not jump as it does.
    Future<double> heightWith(String? caption) async {
      await tester.pumpWidget(
        ShadApp(
          theme: buildLightTheme(),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 300,
                child: DeterminateProgress(
                  key: const ValueKey('bar'),
                  fraction: 0.5,
                  caption: caption,
                  reserveCaptionLine: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return tester.getSize(find.byKey(const ValueKey('bar'))).height;
    }

    expect(await heightWith(null), await heightWith('This takes a minute.'));
  });
}
