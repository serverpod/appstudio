import 'package:appstudio/runner/runner_actions_view.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/hot_reload_buttons.dart';
import 'package:appstudio/ui/server_log/migrations_menu.dart';
import 'package:appstudio/ui/server_log/server_log_view.dart';
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

  ShadIconButton iconButton(WidgetTester tester, String label) =>
      tester.widget<ShadIconButton>(
        find.byWidgetPredicate(
          (w) => w is ShadIconButton && w.semanticLabel == label,
        ),
      );

  group('hot reload and restart buttons', () {
    Widget buttons(RunnerActionsView actions) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            HotReloadButton(actions: actions),
            HotRestartButton(actions: actions),
          ],
        );

    testWidgets('send their action to the runner', (tester) async {
      final actions = FakeRunnerActions(delay: Duration.zero);
      await pump(tester, buttons(actions));

      await tester.tap(find.byIcon(LucideIcons.zap));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(LucideIcons.refreshCcwDot));
      await tester.pumpAndSettle();

      expect(actions.calls, ['hotReload', 'hotRestart']);
    });

    testWidgets('are disabled until the server is running, and dim',
        (tester) async {
      await pump(tester, buttons(FakeRunnerActions(canHotReload: false)));

      for (final label in ['Hot reload', 'Hot restart']) {
        final button = iconButton(tester, label);
        // `enabled` drives the dimming; a null handler alone would not.
        expect(button.enabled, isFalse, reason: label);
        expect(button.onPressed, isNull, reason: label);
      }
    });

    testWidgets('one in flight holds the other off and shows a spinner',
        (tester) async {
      await pump(
        tester,
        buttons(FakeRunnerActions(runningAction: RunnerAction.hotRestart)),
      );

      expect(find.byType(ShadSpinner), findsOneWidget);
      expect(iconButton(tester, 'Hot reload').enabled, isFalse);
    });
  });

  group('migrations menu', () {
    testWidgets('a migration refused for warnings asks, then forces',
        (tester) async {
      final actions = FakeRunnerActions(
        delay: Duration.zero,
        migrationResult: refusedMigration,
      );
      await pump(tester, MigrationsMenu(actions: actions));

      await tester.tap(find.text('Migrations'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create migration'));
      await tester.pumpAndSettle();

      expect(find.text('Create the migration anyway?'), findsOneWidget);
      expect(
        find.textContaining('Column "nickname"'),
        findsOneWidget,
        reason: 'the warning is quoted, since it is what the user decides on',
      );

      await tester.tap(find.text('Create anyway'));
      await tester.pumpAndSettle();

      expect(actions.calls, ['createMigration', 'createMigration(force)']);
      expect(find.text('Created a migration'), findsOneWidget);
    });

    testWidgets('cancelling the force creates nothing', (tester) async {
      final actions = FakeRunnerActions(
        delay: Duration.zero,
        migrationResult: refusedMigration,
      );
      await pump(tester, MigrationsMenu(actions: actions));

      await tester.tap(find.text('Migrations'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create migration'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(actions.calls, ['createMigration']);
    });

    testWidgets('apply reports success', (tester) async {
      final actions = FakeRunnerActions(delay: Duration.zero);
      await pump(tester, MigrationsMenu(actions: actions));

      await tester.tap(find.text('Migrations'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply migrations'));
      await tester.pumpAndSettle();

      expect(actions.calls, ['applyMigrations']);
      expect(find.text('Migrations applied'), findsOneWidget);
    });

    testWidgets('is unavailable without a stack to migrate', (tester) async {
      await pump(
        tester,
        SizedBox(
          width: 640,
          height: 400,
          child: ServerLogView(
            log: sampleRunnerLog(),
            actions: FakeRunnerActions(canMigrate: false),
            source: const ServerLogSource(),
          ),
        ),
      );

      final button = tester.widget<ShadButton>(
        find.ancestor(
          of: find.text('Migrations'),
          matching: find.byType(ShadButton),
        ),
      );
      expect(button.enabled, isFalse);
    });
  });
}
