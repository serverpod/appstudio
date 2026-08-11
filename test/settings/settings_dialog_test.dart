import 'package:appstudio/agent/agent_controller.dart';
import 'package:appstudio/process/serverpod_process.dart';
import 'package:appstudio/session/project_session.dart';
import 'package:appstudio/terminal/studio_terminal.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/toolchain/toolchain_controller.dart';
import 'package:appstudio/ui/settings/providers_settings_pane.dart';
import 'package:appstudio/ui/settings/settings_dialog.dart';
import 'package:appstudio/ui/toolchain/manage_tools_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/agent_flag.dart';
import '../support/toolchain_support.dart';

/// Providers and Tools used to be separate dialogs behind unrelated menus.
/// These cover the part that is easy to get wrong in a merge: opening on the
/// pane the caller asked for, and keeping both panes reachable.
///
/// Providers configures API keys for the OpenCode agent and nothing else, so
/// with the agent switched off there is one pane and no tab strip. Both shapes
/// are pinned here; [kOpenCodeAgentEnabled] picks which set runs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ToolchainController toolchains;
  late AgentController agent;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    toolchains = await emptyToolchainController();
    final session = ProjectSession();
    agent = AgentController(
      toolchains: toolchains,
      session: session,
      process: ServerpodProcessController(
        toolchains: toolchains,
        session: session,
        terminal: StudioTerminal(),
      ),
    );
  });

  Future<void> pump(WidgetTester tester, SettingsTab tab) async {
    await tester.pumpWidget(
      ShadApp(
        theme: buildLightTheme(),
        home: Scaffold(
          body: SettingsDialog(
            agent: agent,
            toolchains: toolchains,
            initialTab: tab,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('opens on Providers when asked', (tester) async {
    await pump(tester, SettingsTab.providers);

    expect(find.byType(ProvidersSettingsPane), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
  }, skip: skipWhenAgentOff);

  testWidgets('with the agent off, a request for Providers lands on Tools', (
    tester,
  ) async {
    // The App menu's Settings item still asks for Providers. Honouring it would
    // park the user on a pane whose "waiting for the agent" spinner can never
    // resolve, because no agent is coming.
    await pump(tester, SettingsTab.providers);

    expect(find.byType(ProvidersSettingsPane), findsNothing);
    expect(find.byType(ManageToolsPane), findsOneWidget);
    // One pane left, so no tab strip: a single tab is a button that does
    // nothing.
    expect(find.text('Providers'), findsNothing);
    expect(find.byType(ShadTabs<SettingsTab>), findsNothing);
    expect(find.text('Settings'), findsOneWidget);
  }, skip: skipWhenAgentOn);

  testWidgets('opens on Tools when asked', (tester) async {
    // The Tools menu item must land on the Tools pane, not make the user hunt
    // for the tab after opening.
    await pump(tester, SettingsTab.tools);

    expect(find.byType(ManageToolsPane), findsOneWidget);
  });

  testWidgets('both tabs are offered', (tester) async {
    await pump(tester, SettingsTab.providers);

    expect(find.text('Providers'), findsWidgets);
    expect(find.text('Tools'), findsWidgets);
  }, skip: skipWhenAgentOff);

  testWidgets('switching to Tools shows the tools pane', (tester) async {
    await pump(tester, SettingsTab.providers);
    expect(find.byType(ManageToolsPane), findsNothing);

    await tester.tap(find.text('Tools').last);
    // Fixed pumps, not pumpAndSettle: with no agent running the Providers pane
    // shows its waiting spinner, which animates forever, and the tab indicator
    // animates too — settling can never complete.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(ManageToolsPane), findsOneWidget);
  }, skip: skipWhenAgentOff);

  testWidgets('has a single Done button, not one per pane', (tester) async {
    // Each pane used to carry its own dialog chrome; a leftover would give the
    // merged dialog two footers.
    await pump(tester, SettingsTab.providers);

    expect(find.text('Done'), findsOneWidget);
  });
}
