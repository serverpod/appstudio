import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:appstudio/toolchain/toolchain_controller.dart';
import 'support/toolchain_support.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:appstudio/session/project_session.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/new_project_dialog.dart';

/// Existing directory the dialog can offer as the default location.
final String _location = Directory.systemTemp
    .createTempSync('appstudio_new_project')
    .path;

Future<void> _pumpDialog(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({
    'new_project_directory': _location,
  });
  late final ProjectSession session;
  late final ToolchainController toolchains;
  // File and process I/O does not complete under the fake async of pumpWidget.
  await tester.runAsync(() async {
    session = ProjectSession();
    await session.loadRecents();
    toolchains = await emptyToolchainController();
  });

  await tester.pumpWidget(
    ShadApp(
      theme: buildLightTheme(),
      home: Scaffold(
        body: NewProjectDialog(toolchains: toolchains, session: session),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('rejects names that cannot be Dart packages', (tester) async {
    await _pumpDialog(tester);

    await tester.enterText(find.byType(ShadInput).first, '2My-App');
    await tester.pump();

    // Uppercase and separators are folded away as the user types.
    expect(find.text('2myapp'), findsOneWidget);
    expect(find.text('Start the name with a letter.'), findsOneWidget);
  });

  testWidgets('shows where the project will be created', (tester) async {
    await _pumpDialog(tester);

    await tester.enterText(find.byType(ShadInput).first, 'my_app');
    await tester.pump();

    expect(find.text('Start the name with a letter.'), findsNothing);
    expect(
      find.textContaining('$_location/my_app', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('create is disabled until the name is valid', (tester) async {
    await _pumpDialog(tester);

    ShadButton createButton() => tester.widget<ShadButton>(
          find.ancestor(
            of: find.text('Create Project'),
            matching: find.byType(ShadButton),
          ),
        );

    expect(createButton().enabled, isFalse);

    await tester.enterText(find.byType(ShadInput).first, 'my_app');
    await tester.pump();
    expect(createButton().enabled, isTrue);

    await tester.enterText(find.byType(ShadInput).first, '2app');
    await tester.pump();
    expect(createButton().enabled, isFalse);
  });
}
