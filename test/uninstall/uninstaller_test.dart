import 'dart:io';

import 'package:appstudio/agent/agent_controller.dart';
import 'package:appstudio/mcp/mcp_controller.dart';
import 'package:appstudio/process/serverpod_process.dart';
import 'package:appstudio/session/project_session.dart';
import 'package:appstudio/terminal/studio_terminal.dart';
import 'package:appstudio/toolchain/toolchain_controller.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/toolchain_paths.dart';
import 'package:appstudio/toolchain/toolchain_requirements.dart';
import 'package:appstudio/toolchain/toolchain.dart';
import 'package:appstudio/uninstall/uninstaller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/toolchain_support.dart';

/// Uninstall is irreversible and touches three separate stores, only one of
/// which is the Application Support directory. Each of these covers a way it
/// could quietly do less than it claims.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late ToolchainPaths paths;
  late ToolchainController toolchains;
  late ServerpodProcessController process;
  late AgentController agent;
  late McpController mcp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'theme_mode': 'dark',
      'toolchain_setup_dismissed': 'manifest-1',
      'recent_projects': <String>['/tmp/a'],
    });
    tmp = await Directory.systemTemp.createTemp('uninstaller');
    paths = ToolchainPaths(p.join(tmp.path, kAppSupportDirName));

    final manifest = await loadTestManifest();
    toolchains = ToolchainController(
      initial: Toolchain(
        ToolchainInventory(manifest: manifest, tools: const {}),
      ),
      manifest: manifest,
      paths: paths,
      requirements: ToolchainRequirements.empty,
    );
    final session = ProjectSession();
    process = ServerpodProcessController(
      toolchains: toolchains,
      session: session,
      terminal: StudioTerminal(),
    );
    agent = AgentController(
      toolchains: toolchains,
      session: session,
      process: process,
    );
    mcp = McpController(
      toolchains: toolchains,
      session: session,
      process: process,
    );
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Uninstaller uninstaller() => Uninstaller(
        toolchains: toolchains,
        process: process,
        agent: agent,
        mcp: mcp,
      );

  /// A stand-in for an install: a file buried in the support directory.
  Future<File> seedSupportDir() async {
    final file = File(p.join(paths.toolchainRoot, 'flutter', '3.44.2', 'bin'));
    await file.parent.create(recursive: true);
    await file.writeAsString('installed');
    return file;
  }

  test('deletes the whole Application Support directory', () async {
    await seedSupportDir();
    expect(await Directory(paths.appSupportRoot).exists(), isTrue);

    final result = await uninstaller().run();

    expect(await Directory(paths.appSupportRoot).exists(), isFalse);
    expect(result.failures, isEmpty, reason: result.failures.join(', '));
    expect(result.isClean, isTrue);
  });

  test('clears preferences, so a relaunch behaves like a fresh install',
      () async {
    await seedSupportDir();
    // The toolchain-setup dialog remembers a dismissal in preferences, not on
    // disk. Leaving it behind would mean a reinstalled app never offers to
    // fetch the tools it just deleted.
    final before = await SharedPreferences.getInstance();
    expect(before.getString('toolchain_setup_dismissed'), isNotNull);

    await uninstaller().run();

    final after = await SharedPreferences.getInstance();
    expect(after.getString('toolchain_setup_dismissed'), isNull);
    expect(after.getString('theme_mode'), isNull);
    expect(after.getStringList('recent_projects'), isNull);
  });

  test('succeeds when there is nothing installed', () async {
    // Uninstalling a never-set-up copy must not report failures at the user.
    final result = await uninstaller().run();

    expect(result.isClean, isTrue);
    expect(await Directory(paths.appSupportRoot).exists(), isFalse);
  });

  test('is idempotent', () async {
    await seedSupportDir();
    expect((await uninstaller().run()).isClean, isTrue);
    expect((await uninstaller().run()).isClean, isTrue);
  });

  test('reports a failure instead of aborting the rest', () async {
    await seedSupportDir();
    // A directory that cannot be removed: make the parent read-only so the
    // recursive delete fails. Everything after it must still run — stopping
    // halfway would leave neither a working install nor a clean machine.
    await Process.run('/bin/chmod', ['500', tmp.path]);
    addTearDown(() => Process.run('/bin/chmod', ['700', tmp.path]));

    final result = await uninstaller().run();

    expect(result.isClean, isFalse);
    expect(
      result.failures,
      contains('deleting the App Studio support folder'),
    );
    // Preferences come after the delete, and must have been cleared anyway.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), isNull);
  });

  test('does not touch the pub cache unless asked', () async {
    // `dart pub cache clean` affects every Dart project on the machine, so it
    // is opt-in. There is no Dart here, so the assertion is that the default
    // path does not even attempt it.
    final result = await uninstaller().run();
    expect(result.failures, isNot(contains('clearing the Dart package cache')));
  });
}
