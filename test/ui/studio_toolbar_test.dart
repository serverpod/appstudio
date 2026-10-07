import 'package:appstudio/runner/server_status.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/studio_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

import '../../widgetbook/fakes/project.dart';
import '../../widgetbook/fakes/runner.dart';
import '../../widgetbook/fakes/tools.dart';

void main() {
  Future<void> pumpAt(WidgetTester tester, double width) async {
    tester.view.physicalSize = Size(width, 200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Align(
          alignment: Alignment.topCenter,
          child: StudioToolbar(
            status: FakeServerStatus(const ServerStatus.running()),
            tools: FakeToolsView(inventory: completeInventory),
            process: FakeFullRestart(),
            actions: FakeRunnerActions(),
            editors: FakeExternalEditors(
              editors: const [cursorEditor, claudeEditor],
            ),
            onManageTools: () {},
          ),
        ),
      ),
    );
  }

  testWidgets('a wide window keeps the full buttons', (tester) async {
    await pumpAt(tester, 1280);

    expect(find.text('Open in Cursor'), findsOneWidget);
    expect(find.text('Publish to Cloud'), findsOneWidget);
    expect(find.text('Open in…'), findsNothing);
  });

  testWidgets('the narrowest window folds them, and nothing overflows',
      (tester) async {
    await pumpAt(tester, 670);

    expect(find.text('Open in…'), findsOneWidget);
    expect(find.text('Open in Cursor'), findsNothing);
    expect(find.text('Running'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
