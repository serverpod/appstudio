import 'dart:io';

import 'package:appstudio/platform/windows/windows_system.dart';
import 'package:appstudio/toolchain/toolchain_installer.dart';
import 'package:appstudio/toolchain/toolchain_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_windows_system.dart';

/// Where Git for Windows' installer put Git, found after it exits. Scratch
/// directories and a [FakeWindowsSystem] only, so this runs on any host.
void main() {
  late Directory tmp;
  late FakeWindowsSystem windows;
  late ToolchainInstaller installer;
  late Map<String, String> env;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('git_location');
    windows = FakeWindowsSystem();
    installer = ToolchainInstaller(
      paths: ToolchainPaths.forHome(tmp.path),
      windows: windows,
    );
    env = {
      'LOCALAPPDATA': p.join(tmp.path, 'Local'),
      'ProgramFiles': p.join(tmp.path, 'Program Files'),
    };
  });

  tearDown(() async {
    installer.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<String> gitAt(String root) async {
    await File(p.join(root, 'cmd', 'git.exe')).create(recursive: true);
    return root;
  }

  void recordInstallPath(RegistryRoot root, String path) {
    windows.values[FakeWindowsSystem.keyFor(
        root, r'Software\GitForWindows', 'InstallPath')] = path;
  }

  test('finds a per-user install where the installer recorded it', () async {
    final root = await gitAt(p.join(tmp.path, 'elsewhere', 'Git'));
    recordInstallPath(RegistryRoot.currentUser, root);
    expect(await installer.installedGitRoot(environment: env), root);
  });

  test('finds a machine-wide install where the installer recorded it',
      () async {
    final root = await gitAt(p.join(tmp.path, 'Program Files', 'Git'));
    recordInstallPath(RegistryRoot.localMachine, root);
    expect(await installer.installedGitRoot(environment: env), root);
  });

  test('falls back to Program Files when nothing is recorded', () async {
    final root = await gitAt(p.join(tmp.path, 'Program Files', 'Git'));
    expect(await installer.installedGitRoot(environment: env), root);
  });

  test('prefers the per-user directory over Program Files', () async {
    final user = await gitAt(p.join(tmp.path, 'Local', 'Programs', 'Git'));
    await gitAt(p.join(tmp.path, 'Program Files', 'Git'));
    expect(await installer.installedGitRoot(environment: env), user);
  });

  test('skips a recorded directory that has no git.exe', () async {
    recordInstallPath(
        RegistryRoot.currentUser, p.join(tmp.path, 'removed', 'Git'));
    final root = await gitAt(p.join(tmp.path, 'Local', 'Programs', 'Git'));
    expect(await installer.installedGitRoot(environment: env), root);
  });

  test('is null when Git is nowhere', () async {
    expect(await installer.installedGitRoot(environment: env), isNull);
  });

  group('windowsInstallPubCache', () {
    test("is the default cache, in lowercase", () {
      expect(
        windowsInstallPubCache({'LOCALAPPDATA': r'C:\Users\Åsa Öberg\AppData\Local'}),
        r'c:\users\åsa öberg\appdata\local\pub\cache',
      );
    });

    test("is the user's own PUB_CACHE when set, whatever its key's case", () {
      expect(
        windowsInstallPubCache({
          'Pub_Cache': r'D:\Pub',
          'LOCALAPPDATA': r'C:\Users\x\AppData\Local',
        }),
        r'd:\pub',
      );
    });

    test('falls back to the profile without LOCALAPPDATA', () {
      expect(windowsInstallPubCache({'USERPROFILE': r'C:\Users\X'}),
          r'c:\users\x\appdata\local\pub\cache');
    });
  });
}
