import 'dart:async';
import 'dart:io';

import 'package:appstudio/agent/agent_controller.dart';
import 'package:appstudio/platform/host.dart';
import 'package:appstudio/process/serverpod_process.dart';
import 'package:appstudio/session/project_session.dart';
import 'package:appstudio/toolchain/install_record.dart';
import 'package:appstudio/toolchain/tool_probe.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/toolchain.dart';
import 'package:appstudio/toolchain/toolchain_controller.dart';
import 'package:appstudio/toolchain/toolchain_installer.dart';
import 'package:appstudio/toolchain/toolchain_paths.dart';
import 'package:appstudio/uninstall/uninstaller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_windows_system.dart';
import '../support/toolchain_support.dart';

/// What uninstall takes off a Windows PC beyond what it takes off a Mac: Git
/// for Windows, Developer Mode, and the preview's browser cache.
///
/// Every file here lives in a scratch directory and every registry value and
/// UAC prompt in a [FakeWindowsSystem], so this runs on any host.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late ToolchainPaths paths;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tmp = await Directory.systemTemp.createTemp('windows_uninstall');
    paths = ToolchainPaths.forHome(tmp.path);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// Git for Windows as its installer leaves it, where App Studio put it.
  Future<RecordedInstall> seedGit({bool withUninstaller = true}) async {
    final root = p.join(tmp.path, 'Programs', 'Git');
    await File(p.join(root, 'cmd', 'git.exe')).create(recursive: true);
    if (withUninstaller) {
      await File(p.join(root, 'unins000.exe')).create(recursive: true);
    }
    return RecordedInstall(
      id: ToolId.git,
      path: root,
      version: '2.51.0',
      installedAt: DateTime.utc(2026),
    );
  }

  /// Git's uninstaller as Inno Setup runs it: back at once, with the work
  /// done a moment later by a copy of itself.
  ({List<List<String>> runs, Future<ProcessResult> Function(String, List<String>) run})
      gitUninstaller({int exitCode = 0, bool removes = true}) {
    final runs = <List<String>>[];
    Future<ProcessResult> run(String exe, List<String> args) async {
      runs.add([exe, ...args]);
      if (removes) {
        Timer(const Duration(milliseconds: 30), () {
          Directory(p.join(p.dirname(exe), 'cmd')).deleteSync(recursive: true);
        });
      }
      return ProcessResult(0, exitCode, '', '');
    }

    return (runs: runs, run: run);
  }

  ToolchainInstaller installer({
    FakeWindowsSystem? windows,
    Future<ProcessResult> Function(String, List<String>)? runProcess,
  }) =>
      ToolchainInstaller(
        paths: paths,
        windows: windows ?? FakeWindowsSystem(),
        pollInterval: const Duration(milliseconds: 10),
        runProcess: runProcess,
      );

  group('Git for Windows', () {
    test('goes through its own uninstaller, silently', () async {
      final git = await seedGit();
      final uninstaller = gitUninstaller();

      await installer(runProcess: uninstaller.run).uninstallGit(git);

      expect(uninstaller.runs, [
        [
          p.join(git.path!, 'unins000.exe'),
          '/VERYSILENT',
          '/NORESTART',
          '/SUPPRESSMSGBOXES',
        ],
      ]);
      // Waited for git.exe to go, then cleared what was left of the folder.
      expect(await Directory(git.path!).exists(), isFalse);
    });

    test('a failing uninstaller is reported', () async {
      final git = await seedGit();
      final uninstaller = gitUninstaller(exitCode: 1, removes: false);

      await expectLater(
        installer(runProcess: uninstaller.run).uninstallGit(git),
        throwsA(isA<ToolInstallException>()),
      );
      expect(await File(p.join(git.path!, 'cmd', 'git.exe')).exists(), isTrue);
    });

    test('with no uninstaller, says where to remove it instead', () async {
      final git = await seedGit(withUninstaller: false);
      final uninstaller = gitUninstaller();

      await expectLater(
        installer(runProcess: uninstaller.run).uninstallGit(git),
        throwsA(isA<ToolInstallException>().having(
            (e) => e.message, 'message', contains('Installed apps'))),
      );
      expect(uninstaller.runs, isEmpty);
    });

    test('already gone is done', () async {
      final uninstaller = gitUninstaller();
      await installer(runProcess: uninstaller.run).uninstallGit(
        RecordedInstall(
          id: ToolId.git,
          path: p.join(tmp.path, 'nowhere'),
          installedAt: DateTime.utc(2026),
        ),
      );
      expect(uninstaller.runs, isEmpty);
    });
  });

  group('Developer Mode', () {
    test('is turned off through one elevated reg add', () async {
      final system = FakeWindowsSystem(onElevated: (s, exe, params) {
        s.setDeveloperMode(false);
        return 0;
      })
        ..setDeveloperMode(true);

      await installer(windows: system).disableDeveloperMode();

      expect(system.elevated.single,
          contains('AllowDevelopmentWithoutDevLicense /t REG_DWORD /d 0'));
    });

    test('a declined prompt leaves it on and says so', () async {
      final system = FakeWindowsSystem()..setDeveloperMode(true);

      await expectLater(
        installer(windows: system).disableDeveloperMode(),
        throwsA(isA<ToolInstallException>()
            .having((e) => e.message, 'message', contains('approval'))),
      );
    });

    test('already off raises no prompt', () async {
      final system = FakeWindowsSystem();
      await installer(windows: system).disableDeveloperMode();
      expect(system.elevated, isEmpty);
    });
  });

  group('what uninstall offers', () {
    Future<ToolchainController> controller(
      InstallRecord record,
      FakeWindowsSystem windows,
    ) async {
      final manifest = await loadTestManifest();
      return ToolchainController(
        initial: Toolchain(
          ToolchainInventory(manifest: manifest, tools: const {}),
        ),
        manifest: manifest,
        paths: paths,
        record: record,
        installer: installer(windows: windows),
        probeSandbox: ProbeSandbox.empty,
      );
    }

    final devMode = RecordedInstall(
      id: ToolId.developerMode,
      installedAt: DateTime.utc(2026),
    );

    test('Git and Developer Mode, when App Studio set them up', () async {
      final record = InstallRecord.empty
          .withTool(await seedGit())
          .withTool(devMode);
      final toolchains = await controller(
        record,
        FakeWindowsSystem()..setDeveloperMode(true),
      );

      expect(await toolchains.removableTools(), [
        ToolId.git,
        ToolId.developerMode,
      ]);
    });

    test('neither, when they are already gone', () async {
      final git = await seedGit();
      await Directory(git.path!).delete(recursive: true);
      final toolchains = await controller(
        InstallRecord.empty.withTool(git).withTool(devMode),
        FakeWindowsSystem(),
      );

      expect(await toolchains.removableTools(), isEmpty);
    });

    test('neither, when App Studio did not set them up', () async {
      await seedGit();
      final toolchains = await controller(
        InstallRecord.empty,
        FakeWindowsSystem()..setDeveloperMode(true),
      );

      expect(await toolchains.removableTools(), isEmpty);
    });
  });

  group('the uninstall', () {
    test('removes ticked Git and Developer Mode, and forgets them', () async {
      final windows = FakeWindowsSystem(onElevated: (s, exe, params) {
        s.setDeveloperMode(false);
        return 0;
      })
        ..setDeveloperMode(true);
      final git = await seedGit();
      final record = InstallRecord.empty.withTool(git).withTool(
            RecordedInstall(
              id: ToolId.developerMode,
              installedAt: DateTime.utc(2026),
            ),
          );
      final manifest = await loadTestManifest();
      final toolchains = ToolchainController(
        initial: Toolchain(
          ToolchainInventory(manifest: manifest, tools: const {}),
        ),
        manifest: manifest,
        paths: paths,
        record: record,
        installer: installer(
          windows: windows,
          runProcess: gitUninstaller().run,
        ),
        probeSandbox: ProbeSandbox.empty,
      );
      final session = ProjectSession();
      final process = ServerpodProcessController(
        toolchains: toolchains,
        session: session,
      );
      addTearDown(process.dispose);

      final result = await Uninstaller(
        toolchains: toolchains,
        process: process,
        agent: AgentController(
          toolchains: toolchains,
          session: session,
          process: process,
        ),
      ).run(const UninstallChoice(
        tools: {ToolId.git, ToolId.developerMode},
      ));

      expect(result.failures, isEmpty, reason: result.failures.join(', '));
      expect(await Directory(git.path!).exists(), isFalse);
      expect(windows.elevated, hasLength(1));
      expect(await toolchains.removableTools(), isEmpty);
    });
  });

  group('the preview cache', () {
    test('is where the Windows runner puts it, and only on Windows', () {
      final windows =
          ToolchainPaths.forHome(r'C:\Users\alex', host: HostPlatform.windows);
      expect(windows.localDataRoot, r'C:\Users\alex\AppData\Local\App Studio');
      expect(
        ToolchainPaths.forHome('/Users/alex', host: HostPlatform.macos)
            .localDataRoot,
        isNull,
      );
    });
  });

  group('deleteDirectory', () {
    test('deletes a folder and everything in it', () async {
      final dir = Directory(p.join(tmp.path, 'data'));
      await File(p.join(dir.path, 'a', 'b')).create(recursive: true);

      await deleteDirectory(dir);

      expect(await dir.exists(), isFalse);
    });

    test('a missing folder is already deleted', () async {
      await deleteDirectory(Directory(p.join(tmp.path, 'missing')));
    });

    test('waits out a file that is open for a moment', () async {
      // Windows refuses to delete an open file. The session's processes and
      // CEF's helpers let go of theirs shortly after shutdown.
      final dir = Directory(p.join(tmp.path, 'cache'));
      final file = File(p.join(dir.path, 'lock'));
      await file.create(recursive: true);
      final open = await file.open(mode: FileMode.append);
      Timer(const Duration(milliseconds: 150), open.closeSync);

      await deleteDirectory(dir, delay: const Duration(milliseconds: 100));

      expect(await dir.exists(), isFalse);
    });

    test('gives up on a file that stays open', () async {
      final dir = Directory(p.join(tmp.path, 'cache'));
      final file = File(p.join(dir.path, 'lock'));
      await file.create(recursive: true);
      final open = await file.open(mode: FileMode.append);
      addTearDown(open.closeSync);

      await expectLater(
        deleteDirectory(
          dir,
          attempts: 2,
          delay: const Duration(milliseconds: 10),
        ),
        throwsA(isA<FileSystemException>()),
      );
    }, skip: !currentHost.isWindows); // POSIX deletes open files.
  });
}
