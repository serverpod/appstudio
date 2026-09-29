import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:appstudio/toolchain/toolchain_controller.dart';
import 'support/toolchain_support.dart';
import 'package:shad/shad.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:appstudio/process/project_creator.dart';
import 'package:appstudio/session/project_session.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/new_project_dialog.dart';
import 'package:appstudio/util/pretty_path.dart';

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
        body: NewProjectDialog(
          actions: SessionNewProjectView(
            toolchains: toolchains,
            session: session,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('cancel goes back to the screen that opened it', (tester) async {
    SharedPreferences.setMockInitialValues({
      'new_project_directory': _location,
    });
    late final ProjectSession session;
    late final ToolchainController toolchains;
    await tester.runAsync(() async {
      session = ProjectSession();
      await session.loadRecents();
      toolchains = await emptyToolchainController();
    });

    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ShadButton(
                onPressed: () => showNewProjectScreen(
                  context,
                  toolchains: toolchains,
                  session: session,
                ),
                child: const Text('Open it'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open it'));
    await tester.pumpAndSettle();
    expect(find.byType(NewProjectDialog), findsOneWidget);
    // A screen, not a dialog: there is no barrier to dismiss it with.
    expect(find.byType(ModalBarrier).hitTestable(), findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(NewProjectDialog), findsNothing);
    expect(find.text('Open it'), findsOneWidget);
  });

  testWidgets('a route refusing to pop still yields to popUntil', (
    tester,
  ) async {
    // `_clearPushedRoutes` in main.dart leans on this. The Create Project
    // screen refuses to pop while the CLI is running, and a swap of the root
    // screen — uninstalling, most of all — has to clear it regardless.
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Builder(
          builder: (context) => ShadButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const PopScope(
                  canPop: false,
                  child: Scaffold(body: Text('pushed')),
                ),
              ),
            ),
            child: const Text('push'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(find.text('pushed'), findsOneWidget);

    tester
        .state<NavigatorState>(find.byType(Navigator))
        .popUntil((route) => route.isFirst);
    await tester.pumpAndSettle();
    expect(find.text('pushed'), findsNothing);
  });

  testWidgets('rejects names that cannot be Dart packages', (tester) async {
    await _pumpDialog(tester);

    await tester.enterText(find.byType(ShadInput).first, '2My-App');
    await tester.pump();

    // Uppercase and separators are folded away as the user types.
    expect(find.text('2myapp'), findsOneWidget);
    expect(find.text('Start the name with a letter.'), findsOneWidget);
  });

  testWidgets('shows the location in a disabled field', (tester) async {
    await _pumpDialog(tester);

    final location = tester.widget<ShadInput>(find.byType(ShadInput).last);
    expect(location.enabled, isFalse);
    expect(location.controller?.text, prettyPath(_location));
  });

  testWidgets('every editor is offered, none preselected', (tester) async {
    await _pumpDialog(tester);

    for (final ide in IdeIntegration.values) {
      expect(find.text(ide.label), findsOneWidget);
      final radio = tester.widget<ShadRadio<IdeIntegration>>(
        find.ancestor(
          of: find.text(ide.label),
          matching: find.byType(ShadRadio<IdeIntegration>),
        ),
      );
      expect(radio.value, ide, reason: ide.label);
      expect(radio.enabled, isTrue, reason: ide.label);
    }
    // Radios, so the empty answer cannot be expressed. That is what makes
    // picking one mandatory without a prompt raised after the fact.
    expect(find.byType(ShadCheckbox), findsNothing);
  });

  testWidgets('create waits for a name *and* an editor', (tester) async {
    // Picking an editor is mandatory. A disabled Create beside an unanswered
    // question replaced the "No external editor selected" prompt, which could
    // only be raised after the user had already committed.
    await _pumpDialog(tester);

    ShadButton createButton() => tester.widget<ShadButton>(
          find.ancestor(
            of: find.text('Create'),
            matching: find.byType(ShadButton),
          ),
        );

    expect(createButton().enabled, isFalse);

    // A valid name is not enough on its own.
    await tester.enterText(find.byType(ShadInput).first, 'my_app');
    await tester.pump();
    expect(createButton().enabled, isFalse);

    await tester.tap(find.text('Cursor'));
    await tester.pump();
    expect(createButton().enabled, isTrue);

    // And the name still has to hold up.
    await tester.enterText(find.byType(ShadInput).first, '2app');
    await tester.pump();
    expect(createButton().enabled, isFalse);
  });

  testWidgets('a name and an editor creates, with nothing to confirm', (
    tester,
  ) async {
    await _pumpDialog(tester);

    await tester.enterText(find.byType(ShadInput).first, 'my_app');
    await tester.tap(find.text('Cursor'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ShadButton, 'Create'));
    // Fixed pumps, not pumpAndSettle: once creation starts `ShadProgress`
    // animates forever and settling never completes.
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Creating my_app'), findsOneWidget);
    // Nothing can reach the empty answer now, so there is nothing left to ask.
    expect(find.text('No external editor selected'), findsNothing);
  });
}
