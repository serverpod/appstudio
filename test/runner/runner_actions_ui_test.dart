import 'package:appstudio/runner/runner_actions_view.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/hot_restart_button.dart';
import 'package:appstudio/ui/migration_commands.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';

import '../../widgetbook/fakes/runner.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Scaffold(body: Center(child: child)),
      ),
    );
    await tester.pump();
  }

  ShadIconButton hotRestart(WidgetTester tester) =>
      tester.widget<ShadIconButton>(find.byType(ShadIconButton));

  group('hot restart button', () {
    testWidgets('sends the restart to the runner', (tester) async {
      final actions = FakeRunnerActions(delay: Duration.zero);
      await pump(tester, HotRestartButton(actions: actions));

      await tester.tap(find.byIcon(LucideIcons.zap));
      await tester.pumpAndSettle();

      expect(actions.calls, ['hotRestart']);
    });

    testWidgets('is disabled until the server is running, and dims',
        (tester) async {
      await pump(
        tester,
        HotRestartButton(actions: FakeRunnerActions(canHotRestart: false)),
      );

      // `enabled` drives the dimming; a null handler alone would not.
      expect(hotRestart(tester).enabled, isFalse);
      expect(hotRestart(tester).onPressed, isNull);
    });

    testWidgets('shows a spinner while restarting, and is held off',
        (tester) async {
      await pump(
        tester,
        HotRestartButton(
          actions: FakeRunnerActions(runningAction: RunnerAction.hotRestart),
        ),
      );

      expect(find.byType(ShadSpinner), findsOneWidget);
      expect(hotRestart(tester).enabled, isFalse);
    });
  });

  group('migration commands', () {
    /// Stands in for the Server menu: a button that runs [command] with the
    /// context under the toaster and the navigator, as `main.dart` does.
    Widget trigger(
      Future<void> Function(BuildContext, RunnerActionsView) command,
      RunnerActionsView actions,
    ) =>
        Builder(
          builder: (context) => ShadButton(
            onPressed: () => command(context, actions),
            child: const Text('Run'),
          ),
        );

    testWidgets('create and apply creates, then applies', (tester) async {
      final actions = FakeRunnerActions(delay: Duration.zero);
      await pump(tester, trigger(createAndApplyMigrations, actions));

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(actions.calls, ['createMigration', 'applyMigrations']);
      expect(find.text('Migration created and applied'), findsOneWidget);
    });

    testWidgets('a create refused for warnings asks, forces, then applies',
        (tester) async {
      final actions = FakeRunnerActions(
        delay: Duration.zero,
        migrationResult: refusedMigration,
      );
      await pump(tester, trigger(createAndApplyMigrations, actions));

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(find.text('Create the migration anyway?'), findsOneWidget);
      expect(
        find.textContaining('Column "nickname"'),
        findsOneWidget,
        reason: 'the warning is quoted, since it is what the user decides on',
      );

      await tester.tap(find.text('Create anyway'));
      await tester.pumpAndSettle();

      expect(actions.calls, [
        'createMigration',
        'createMigration(force)',
        'applyMigrations',
      ]);
    });

    testWidgets('cancelling the force creates and applies nothing',
        (tester) async {
      final actions = FakeRunnerActions(
        delay: Duration.zero,
        migrationResult: refusedMigration,
      );
      await pump(tester, trigger(createAndApplyMigrations, actions));

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(actions.calls, ['createMigration']);
    });

    testWidgets('does nothing without a stack to migrate', (tester) async {
      final actions = FakeRunnerActions(canMigrate: false);
      await pump(tester, trigger(createAndApplyMigrations, actions));

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(actions.calls, isEmpty);
    });

    testWidgets('repair creates and does not apply', (tester) async {
      final actions = FakeRunnerActions(delay: Duration.zero);
      await pump(tester, trigger(createRepairMigration, actions));

      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();

      expect(actions.calls, ['createRepairMigration']);
      expect(find.text('Created a repair migration'), findsOneWidget);
    });
  });
}
