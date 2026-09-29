import 'dart:io';

import 'package:appstudio/agent/agent_controller.dart';
import 'package:appstudio/process/serverpod_process.dart';
import 'package:appstudio/session/project_session.dart';
import 'package:appstudio/terminal/studio_terminal.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/toolchain.dart';
import 'package:appstudio/toolchain/toolchain_controller.dart';
import 'package:appstudio/toolchain/toolchain_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/agent_flag.dart';
import '../support/toolchain_support.dart';

/// Settings brings the agent up on a scratch directory when no project is
/// open, so provider keys can be configured before there is a project.
///
/// The failure that matters is the reverse one: closing Settings must never
/// tear down an agent it did not start, which would kill a live session.
///
/// With [kOpenCodeAgentEnabled] off there is no Providers tab for a scratch
/// serve to answer, so `startForSettings` is a no-op — the tests that pin what
/// a real start does are skipped rather than deleted, and the ones covering
/// "does nothing" hold in both states.
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
      paths: ToolchainPaths(home: appSupport.path, appSupportRoot: appSupport.path),
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
  }, skip: skipWhenAgentOff);

  test('startForSettings reports failure rather than throwing', () async {
    // No opencode in this toolchain, so the start cannot succeed. Settings
    // must still open.
    await agent.startForSettings();

    expect(agent.agentReady, isFalse);
    expect(agent.connection, AgentConnectionState.error);
  }, skip: skipWhenAgentOff);

  test('startForSettings does nothing with the agent switched off', () async {
    await agent.startForSettings();

    // Not even the scratch directory: there is no Providers tab to fill in, so
    // nothing is spawned and nothing is left behind.
    expect(
      Directory('${appSupport.path}/agent-scratch').existsSync(),
      isFalse,
    );
    expect(agent.isServeRunning, isFalse);
    expect(agent.connection, AgentConnectionState.idle);
  }, skip: skipWhenAgentOn);

  test('stopIfStartedForSettings does nothing when it did not start', () async {
    // The guard that protects a live project session from being torn down
    // when Settings closes.
    await agent.stopIfStartedForSettings();
    await agent.stopIfStartedForSettings();

    expect(agent.isServeRunning, isFalse);
  });

  test('closing Settings mid-start does not leave an unowned serve', () async {
    // Deliberately not awaited: this closes Settings while the scratch
    // directory is still being created. Two bugs used to live in that window —
    // the ownership flag was set *after* the await, so the stop declined to act,
    // and the start then went ahead regardless of having been disowned. Either
    // one leaves an `opencode serve` running that nothing will stop until quit.
    final starting = agent.startForSettings();
    await agent.stopIfStartedForSettings();
    await starting;

    expect(agent.isServeRunning, isFalse);
    // Idle, not `error`: the start bailed rather than running and failing.
    expect(agent.connection, AgentConnectionState.idle);
  });

  test('stop() is awaitable, so a quit can wait for the child process',
      () async {
    // `dispose()` is synchronous and could only fire the teardown and return,
    // which is what orphaned every `opencode serve` on quit. `teardownSession`
    // calls this instead.
    await agent.startForSettings();
    expect(agent.connection, AgentConnectionState.error);

    await agent.stop();

    expect(agent.isServeRunning, isFalse);
    expect(agent.connection, AgentConnectionState.idle);
  }, skip: skipWhenAgentOff);
}
