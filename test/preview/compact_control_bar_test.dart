import 'package:appstudio/preview/preview_device.dart';
import 'package:appstudio/preview/preview_mode_controller.dart';
import 'package:appstudio/runner/server_status.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/preview_header_bars.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

import '../../widgetbook/fakes/runner.dart';

void main() {
  testWidgets('the control bar fits the narrowest compact window',
      (tester) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Center(
          child: UnconstrainedBox(
            child: CompactControlBar(
              status: FakeServerStatus(const ServerStatus.busy('Compiling')),
              viewMode: PreviewViewMode.phonePortrait,
              previewBrightness: Brightness.light,
              onViewModeChanged: (_) {},
              onPreviewThemeChanged: (_) {},
              onExpand: () {},
            ),
          ),
        ),
      ),
    );

    // The bar's own surface, not the full-width row it is centred in.
    final bar = find.descendant(
      of: find.byType(CompactControlBar),
      matching: find.byType(Container),
    );
    final width = tester.getSize(bar.first).width;

    // A little room either side, so the bar never touches the window edge.
    expect(width + 2 * 12, lessThanOrEqualTo(kCompactMinWindowWidth));
  });
}
