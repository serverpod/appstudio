import 'dart:io';

import 'package:appstudio/agent/agent_controller.dart';
import 'package:appstudio/process/serverpod_process.dart';
import 'package:appstudio/session/project_session.dart';
import 'package:appstudio/toolchain/toolchain_controller.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/toolchain_paths.dart';
import 'package:appstudio/toolchain/install_record.dart';
import 'package:appstudio/toolchain/tool_probe.dart';
import 'package:appstudio/toolchain/toolchain.dart';
import 'package:appstudio/uninstall/uninstaller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/toolchain_support.dart';

/// Uninstall is irreversible and reaches well outside the app: the user's
/// shell config, `~/develop`, `~/.serverpod`. Each of these covers a way it
/// could quietly do less than it claims — or more.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late ToolchainPaths paths;
  late ToolchainController toolchains;
  late ServerpodProcessController process;
  late AgentController agent;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'theme_mode': 'dark',
      'toolchain_setup_dismissed': 'manifest-1',
      'recent_projects': <String>['/tmp/a'],
    });
    tmp = await Directory.systemTemp.createTemp('uninstaller');
    // A scratch home: the steps under test delete ~/.serverpod and
    // ~/develop/flutter.
    paths = ToolchainPaths.forHome(tmp.path);

    final manifest = await loadTestManifest();
    toolchains = ToolchainController(
      initial: Toolchain(
        ToolchainInventory(manifest: manifest, tools: const {}),
      ),
      manifest: manifest,
      paths: paths,
      record: await InstallRecord.load(paths.installRecordFile),
      probeSandbox: ProbeSandbox.empty,
    );
    final session = ProjectSession();
    process = ServerpodProcessController(
      toolchains: toolchains,
      session: session,
    );
    agent = AgentController(
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
      );

  Future<UninstallResult> run({Set<ToolId> tools = const {}}) =>
      uninstaller().run(UninstallChoice(tools: tools));

  /// App Studio's own data: something in the support directory.
  Future<File> seedSupportDir() async {
    final file = File(p.join(paths.appSupportRoot, 'agent-scratch', 'x'));
    await file.parent.create(recursive: true);
    await file.writeAsString('data');
    return file;
  }

  /// A Flutter SDK App Studio installed, with the PATH line it added, and a
  /// controller that knows about it.
  Future<String> seedOwnedFlutter(String zprofile) async {
    final bin = File(p.join(paths.flutterInstallDir, 'bin', 'flutter'));
    await bin.parent.create(recursive: true);
    await bin.writeAsString('');
    const line = r'export PATH="$HOME/develop/flutter/bin:$PATH"';
    await File(zprofile).writeAsString('# mine\n$line\n');
    final record = InstallRecord.empty.withTool(RecordedInstall(
      id: ToolId.flutter,
      path: paths.flutterInstallDir,
      installedAt: DateTime.utc(2026),
      pathLines: [RecordedPathLine(file: zprofile, line: line)],
    ));
    await record.save(paths.installRecordFile);
    toolchains = ToolchainController(
      initial: toolchains.current,
      manifest: toolchains.manifest,
      paths: paths,
      record: record,
      probeSandbox: ProbeSandbox.empty,
    );
    return line;
  }

  test('deletes App Studio\'s own data', () async {
    await seedSupportDir();

    final result = await run();

    expect(await Directory(paths.appSupportRoot).exists(), isFalse);
    expect(result.failures, isEmpty, reason: result.failures.join(', '));
  });

  test('clears preferences, so a relaunch behaves like a fresh install',
      () async {
    await run();

    final after = await SharedPreferences.getInstance();
    expect(after.getString('theme_mode'), isNull);
    expect(after.getStringList('recent_projects'), isNull);
  });

  test('succeeds when there is nothing installed', () async {
    final result = await run();
    expect(result.isClean, isTrue, reason: result.failures.join(', '));
  });

  test('is idempotent', () async {
    await seedSupportDir();
    expect((await run()).isClean, isTrue);
    expect((await run()).isClean, isTrue);
  });

  test('removes what an earlier build installed, whatever is ticked', () async {
    final legacy = Directory(p.join(paths.legacyToolchainRoot, 'flutter'));
    await legacy.create(recursive: true);

    await run();

    expect(await legacy.exists(), isFalse);
  });

  test('removes a ticked Flutter and exactly its PATH line', () async {
    final zprofile = p.join(tmp.path, '.zprofile');
    await seedOwnedFlutter(zprofile);

    final result = await run(tools: {ToolId.flutter});

    expect(result.failures, isEmpty, reason: result.failures.join(', '));
    expect(await Directory(paths.flutterInstallDir).exists(), isFalse);
    expect(await File(zprofile).readAsString(), '# mine\n');
    // Nothing App Studio installed is left, so neither is the record.
    expect(await File(paths.installRecordFile).exists(), isFalse);
  });

  test('leaves an unticked Flutter alone, and remembers it is ours', () async {
    final zprofile = p.join(tmp.path, '.zprofile');
    final line = await seedOwnedFlutter(zprofile);

    await run();

    expect(await Directory(paths.flutterInstallDir).exists(), isTrue);
    expect(await File(zprofile).readAsString(), contains(line));
    final record = await InstallRecord.load(paths.installRecordFile);
    expect(record.owns(ToolId.flutter), isTrue);
  });

  test('keeps ~/.serverpod unless the Serverpod CLI goes', () async {
    // It is the CLI's own state — the cloud login among it — and the user may
    // have a Serverpod CLI App Studio never touched.
    final login = File(p.join(paths.serverpodStateDir, 'cloud', 'auth.json'));
    await login.parent.create(recursive: true);
    await login.writeAsString('{}');

    await run();

    expect(await login.exists(), isTrue);
  });

  test('deletes ~/.serverpod with the Serverpod CLI, but keeps the record of '
      'what else App Studio installed', () async {
    final zprofile = p.join(tmp.path, '.zprofile');
    await seedOwnedFlutter(zprofile);
    final login = File(p.join(paths.serverpodStateDir, 'cloud', 'auth.json'));
    await login.parent.create(recursive: true);
    await login.writeAsString('{}');

    await run(tools: {ToolId.serverpodCli});

    expect(await login.exists(), isFalse);
    final record = await InstallRecord.load(paths.installRecordFile);
    expect(record.owns(ToolId.flutter), isTrue);
  });

  test('reports a failure instead of aborting the rest', () async {
    await seedSupportDir();
    // Make the support directory's parent read-only so the recursive delete
    // fails. Everything after it must still run — stopping halfway would leave
    // neither a working install nor a clean machine.
    final parent = p.dirname(paths.appSupportRoot);
    await Process.run('/bin/chmod', ['500', parent]);
    addTearDown(() => Process.run('/bin/chmod', ['700', parent]));

    final result = await run();

    expect(result.isClean, isFalse);
    expect(result.failures, contains('deleting the App Studio support folder'));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('theme_mode'), isNull);
    // `chmod` makes the delete fail; Windows needs an ACL for that.
  }, testOn: 'mac-os || linux');

  test('leaves the Dart package cache alone while Flutter stays', () async {
    final cache = Directory(p.join(tmp.path, '.pub-cache', 'hosted'));
    await cache.create(recursive: true);

    await run(tools: {ToolId.serverpodCli});

    expect(await cache.exists(), isTrue);
  });

  test('clears the Dart package cache along with Flutter', () async {
    final zprofile = p.join(tmp.path, '.zprofile');
    await seedOwnedFlutter(zprofile);
    // `~/.pub-cache` on macOS, `AppData\Local\Pub\Cache` on Windows.
    final cache = Directory(p.join(paths.defaultPubCache, 'hosted'));
    await cache.create(recursive: true);

    final result = await run(tools: {ToolId.flutter});

    expect(result.failures, isEmpty, reason: result.failures.join(', '));
    expect(await Directory(paths.defaultPubCache).exists(), isFalse);
  });
}
