import 'package:appstudio/agent/agent_controller.dart';
import 'package:appstudio/platform/windows_app_menu.dart';
import 'package:appstudio/process/serverpod_process.dart';
import 'package:appstudio/session/project_session.dart';
import 'package:appstudio/theme/theme_controller.dart';
import 'package:appstudio/ui/server_log/log_view_controller.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/toolchain_support.dart';

/// The menu strip and its `Ctrl` shortcuts. It is plain Flutter, so unlike the
/// macOS menu it runs on any host.
void main() {
  late LogViewController logView;
  late ServerpodProcessController process;
  late ProjectSession session;
  late AgentController agent;
  var newProjects = 0;
  var migrations = 0;
  var canOpenProjects = true;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    newProjects = 0;
    migrations = 0;
    canOpenProjects = true;
    final toolchains = await emptyToolchainController();
    session = ProjectSession();
    process = ServerpodProcessController(
      toolchains: toolchains,
      session: session,
      dependencies: (_, _, _) async {},
    );
    agent = AgentController(
      toolchains: toolchains,
      session: session,
      process: process,
    );
    logView = LogViewController();
  });

  tearDown(() => process.dispose());

  Future<void> pumpMenu(WidgetTester tester) async {
    await tester.pumpWidget(
      ShadApp(
        home: WindowsAppMenuBar(
          session: session,
          process: process,
          agent: agent,
          themeController: ThemeController(),
          logView: logView,
          onNewProject: () => newProjects++,
          onCheckForUpdates: () {},
          onUninstall: () {},
          canCheckForUpdates: () => false,
          updatesUnavailableReason: () => null,
          onSetAutomaticUpdates: (_) {},
          automaticUpdatesEnabled: () => false,
          canOpenProjects: () => canOpenProjects,
          onCreateAndApplyMigrations: () => migrations++,
          onCreateRepairMigration: () {},
          changes: ChangeNotifier(),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  Future<void> ctrl(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  testWidgets('the menus in the Windows order', (tester) async {
    await pumpMenu(tester);

    for (final title in ['File', 'View', 'Server', 'Logs', 'Help']) {
      expect(find.text(title), findsOneWidget);
    }
    final x = [
      for (final title in ['File', 'View', 'Server', 'Logs', 'Help'])
        tester.getTopLeft(find.text(title)).dx,
    ];
    expect(x, [...x]..sort());
  });

  testWidgets('Ctrl+N opens the New Project screen', (tester) async {
    await pumpMenu(tester);

    await ctrl(tester, LogicalKeyboardKey.keyN);

    expect(newProjects, 1);
  });

  testWidgets('no New Project while setup owns the screen', (tester) async {
    canOpenProjects = false;
    await pumpMenu(tester);

    await ctrl(tester, LogicalKeyboardKey.keyN);

    expect(newProjects, 0);
  });

  testWidgets('Ctrl+M does nothing with no server to migrate', (tester) async {
    await pumpMenu(tester);

    await ctrl(tester, LogicalKeyboardKey.keyM);

    expect(migrations, 0);
  });

  testWidgets('Ctrl+L needs a project to show the logs of', (tester) async {
    await pumpMenu(tester);

    await ctrl(tester, LogicalKeyboardKey.keyL);

    expect(logView.visible, isFalse);
  });

  testWidgets('a key without Ctrl is left alone', (tester) async {
    await pumpMenu(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pump();

    expect(newProjects, 0);
  });

  testWidgets('the shortcuts go with the menu', (tester) async {
    await pumpMenu(tester);
    await tester.pumpWidget(const SizedBox());

    await ctrl(tester, LogicalKeyboardKey.keyN);

    expect(newProjects, 0);
  });
}
