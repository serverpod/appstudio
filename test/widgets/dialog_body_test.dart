import 'dart:io';

import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/widgets/dialog_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

void main() {
  /// The distance from the bottom of [above] to the top of the button.
  Future<double> spaceAboveButton(
    WidgetTester tester, {
    required Widget dialogChild,
    required Finder above,
  }) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: Center(
            child: ShadDialog.alert(
              title: const Text('Title'),
              description: const Text('Description'),
              actions: [
                ShadButton(onPressed: () {}, child: const Text('OK')),
              ],
              child: dialogChild,
            ),
          ),
        ),
      ),
    );
    final button = tester.getRect(find.widgetWithText(ShadButton, 'OK'));
    return button.top - tester.getRect(above).bottom;
  }

  testWidgets('the same space above the buttons, with content or without',
      (tester) async {
    final textOnly = await spaceAboveButton(
      tester,
      dialogChild: const DialogBody(),
      above: find.text('Description'),
    );
    final withContent = await spaceAboveButton(
      tester,
      dialogChild: const DialogBody(
        child: SizedBox(key: ValueKey('content'), height: 40, width: 200),
      ),
      above: find.byKey(const ValueKey('content')),
    );

    expect(textOnly, kDialogActionsSpacing);
    expect(withContent, kDialogActionsSpacing);
  });

  test('every dialog in the app goes through DialogBody', () {
    // shad's own gap above the buttons is 4px in this style; a dialog that
    // skips DialogBody puts its text right on top of its buttons.
    final missing = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final source = file.readAsStringSync();
      final dialogs = RegExp(r'ShadDialog(\.alert)?\(').allMatches(source);
      final bodies = RegExp(r'DialogBody\(').allMatches(source);
      if (bodies.length < dialogs.length) missing.add(file.path);
    }
    expect(missing, isEmpty);
  });
}
