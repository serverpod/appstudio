import 'dart:io';

import 'package:appstudio/agent/agent_controller.dart';
import 'package:appstudio/process/serverpod_process.dart';
import 'package:appstudio/session/project_session.dart';
import 'package:appstudio/terminal/studio_terminal.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/toolchain.dart';
import 'package:appstudio/toolchain/toolchain_controller.dart';
import 'package:appstudio/toolchain/toolchain_paths.dart';
import 'package:appstudio/toolchain/toolchain_requirements.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/toolchain_support.dart';

/// Settings brings the agent up on a scratch directory when no project is
/// open, so provider keys can be configured before there is a project.
///
/// The failure that matters is the reverse one: closing Settings must never
/// tear down an agent it did not start, which would kill a live session.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory appSupport;
  late AgentController agent;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    appSupport = await Directory.systemTemp.createTemp('appstudio_agent_test');
    final manifest = await loadTestManifest();
    // No tools resolved, so `opencode` is unavailable — start fails, which is
    // exactly the path under test.
    final toolchains = ToolchainController(
      initial: Toolchain(
        ToolchainInventory(manifest: manifest, tools: const {}),
      ),
      manifest: manifest,
      paths: ToolchainPaths(appSupport.path),
      requirements: ToolchainRequirements.empty,
    );
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

  tearDown(() async {
    if (appSupport.existsSync()) await appSupport.delete(recursive: true);
  });

  test('startForSettings creates the working directory serve needs', () async {
    await agent.startForSettings();

    // Without this directory `Process.start` fails on `workingDirectory`
    // before opencode is ever consulted.
    expect(
      Directory('${appSupport.path}/agent-scratch').existsSync(),
      isTrue,
    );
  });

  test('startForSettings reports failure rather than throwing', () async {
    // No opencode in this toolchain, so the start cannot succeed. Settings
    // must still open.
    await agent.startForSettings();

    expect(agent.agentReady, isFalse);
    expect(agent.connection, AgentConnectionState.error);
  });

  test('stopIfStartedForSettings does nothing when it did not start', () async {
    // The guard that protects a live project session from being torn down
    // when Settings closes.
    await agent.stopIfStartedForSettings();
    await agent.stopIfStartedForSettings();

    expect(agent.isServeRunning, isFalse);
  });
}
