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
        body: NewProjectDialog(toolchains: toolchains, session: session),
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
      final box = tester.widget<ShadCheckbox>(
        find.ancestor(
          of: find.text(ide.label),
          matching: find.byType(ShadCheckbox),
        ),
      );
      expect(box.value, isFalse, reason: ide.label);
      expect(box.enabled, isTrue, reason: ide.label);
    }
    // Its box says nothing about it — OpenCode is installed either way.
    expect(IdeIntegration.opencode.builtIn, isTrue);
  });

  group('creating with no external editor', () {
    /// A valid name, then Create. Fixed pumps throughout: once creation
    /// starts, `ShadProgress` animates forever and `pumpAndSettle` never
    /// returns.
    Future<void> pressCreate(WidgetTester tester) async {
      await tester.enterText(find.byType(ShadInput).first, 'my_app');
      await tester.pump();
      await tester.tap(find.widgetWithText(ShadButton, 'Create'));
      await tester.pump(const Duration(milliseconds: 400));
    }

    testWidgets('warns, and Pick Editor goes back to the form', (tester) async {
      await _pumpDialog(tester);
      await pressCreate(tester);

      expect(
        find.textContaining('recommended that you use App Studio'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(ShadButton, 'Pick Editor'));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('No external editor selected'), findsNothing);
      // Back on the form, not creating.
      expect(find.text('External AI editors'), findsOneWidget);
      expect(find.text('Creating my_app'), findsNothing);
    });

    testWidgets('Continue creates anyway', (tester) async {
      await _pumpDialog(tester);
      await pressCreate(tester);

      await tester.tap(find.widgetWithText(ShadButton, 'Continue'));
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('No external editor selected'), findsNothing);
      expect(find.text('Creating my_app'), findsOneWidget);
    });

    testWidgets('OpenCode alone does not count as one', (tester) async {
      await _pumpDialog(tester);
      await tester.tap(find.text('OpenCode'));
      await tester.pump();
      await pressCreate(tester);

      expect(find.text('No external editor selected'), findsOneWidget);
    });

    testWidgets('picking one skips the warning', (tester) async {
      await _pumpDialog(tester);
      await tester.tap(find.text('Cursor'));
      await tester.pump();
      await pressCreate(tester);

      expect(find.text('No external editor selected'), findsNothing);
      expect(find.text('Creating my_app'), findsOneWidget);
    });
  });

  testWidgets('create is disabled until the name is valid', (tester) async {
    await _pumpDialog(tester);

    ShadButton createButton() => tester.widget<ShadButton>(
          find.ancestor(
            of: find.text('Create'),
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
