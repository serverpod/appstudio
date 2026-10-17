import 'dart:convert';
import 'dart:io';

import 'package:appstudio/platform/host_platform.dart';
import 'package:appstudio/platform/windows/windows_system.dart';
import 'package:appstudio/toolchain/install_plan.dart';
import 'package:appstudio/toolchain/install_record.dart';
import 'package:appstudio/toolchain/shell_profile.dart';
import 'package:appstudio/toolchain/tool_probe.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/toolchain_installer.dart';
import 'package:appstudio/toolchain/toolchain_manifest.dart';
import 'package:appstudio/toolchain/toolchain_paths.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_windows_system.dart';
import '../support/toolchain_support.dart';

/// The Windows toolchain: which tools, Developer Mode, the user `Path` in the
/// registry and Git's release. Everything runs against a fake registry, so
/// the suite checks it on a Mac as well as on Windows.
void main() {
  const windows = HostPlatform.windows;
  const userPath = r'HKCU\Environment\Path';
  final devMode = FakeWindowsSystem.keyFor(
      RegistryRoot.localMachine, kAppModelUnlockKey, kDeveloperModeValue);
  final policy = FakeWindowsSystem.keyFor(
      RegistryRoot.localMachine, kAppxPolicyKey, kDeveloperModeValue);

  group('the tool set', () {
    test('Windows needs Developer Mode and Git, in that order, before Flutter',
        () {
      expect(ToolId.requiredOn(windows), [
        ToolId.developerMode,
        ToolId.git,
        ToolId.flutter,
        ToolId.serverpodCli,
      ]);
    });

    test('macOS keeps its three tools, in their order', () {
      expect(ToolId.requiredOn(HostPlatform.macos), [
        ToolId.commandLineTools,
        ToolId.flutter,
        ToolId.serverpodCli,
      ]);
    });

    test('one manifest file serves both, each host reading its own tools',
        () async {
      final source = await loadTestManifestSource();
      final onWindows = ToolManifest.tryParse(source, host: windows)!;
      final onMac = ToolManifest.tryParse(source, host: HostPlatform.macos)!;
      expect(onWindows.tools.keys, ToolId.requiredOn(windows));
      expect(onMac.tools.keys, ToolId.requiredOn(HostPlatform.macos));
    });
  });

  group('Developer Mode', () {
    Future<ToolStatus> probe(FakeWindowsSystem system) async {
      final manifest =
          ToolManifest.tryParse(await loadTestManifestSource(), host: windows)!;
      final inventory = await ToolProbe(
        paths: ToolchainPaths.forHome(r'C:\Users\alex', host: windows),
        manifest: manifest,
        record: InstallRecord.empty,
        sandbox: ProbeSandbox(
          runner: (executable, arguments, {environment}) async =>
              ProcessResult(0, 1, '', ''),
          loginShellPath: () async => null,
          environment: const {'PATH': ''},
          windows: system,
        ),
      ).inventory();
      return inventory[ToolId.developerMode]!;
    }

    test('on is satisfied', () async {
      final status = await probe(FakeWindowsSystem(values: {devMode: 1}));
      expect(status.isSatisfied, isTrue);
      expect(status.action, ToolAction.none);
    });

    test('off is something App Studio turns on', () async {
      final status = await probe(FakeWindowsSystem());
      expect(status.isSatisfied, isFalse);
      expect(status.action, ToolAction.install);
    });

    test('a policy that turns it off is named', () async {
      final status = await probe(FakeWindowsSystem(values: {policy: 0}));
      expect(status.candidates.single.reason, contains('policy'));
    });

    ToolchainInstaller installer(FakeWindowsSystem system) =>
        ToolchainInstaller(
          paths: ToolchainPaths.forHome(r'C:\Users\alex', host: windows),
          windows: system,
        );

    test('is turned on through one elevated reg add', () async {
      final system = FakeWindowsSystem(onElevated: (s, exe, params) {
        s.setDeveloperMode(true);
        return 0;
      });
      final installed =
          await installer(system).enableDeveloperMode(onProgress: (_) {});
      expect(installed.id, ToolId.developerMode);
      expect(system.elevated.single, contains('reg.exe'));
      expect(system.elevated.single,
          contains('AllowDevelopmentWithoutDevLicense /t REG_DWORD /d 1'));
    });

    test('a declined prompt fails with the way to do it by hand', () async {
      final system = FakeWindowsSystem();
      await expectLater(
        installer(system).enableDeveloperMode(onProgress: (_) {}),
        throwsA(isA<ToolInstallException>().having((e) => e.message,
            'message', allOf(contains('approval'), contains('For developers')))),
      );
    });

    test('a policy is reported without raising a prompt it cannot pass',
        () async {
      final system = FakeWindowsSystem(values: {policy: 0});
      await expectLater(
        installer(system).enableDeveloperMode(onProgress: (_) {}),
        throwsA(isA<ToolInstallException>()
            .having((e) => e.message, 'message', contains('policy'))),
      );
      expect(system.elevated, isEmpty);
    });
  });

  group('the user Path', () {
    ToolchainInstaller installer(FakeWindowsSystem system) =>
        ToolchainInstaller(
          paths: ToolchainPaths.forHome(r'C:\Users\alex', host: windows),
          windows: system,
        );

    test('a directory is added at the end, keeping %VARIABLES% as stored',
        () async {
      final system = FakeWindowsSystem(values: {
        userPath: r'%USERPROFILE%\AppData\Local\Microsoft\WindowsApps',
      });
      final line = await installer(system)
          .addToShellPath(r'C:\Users\alex\develop\flutter\bin', 'ignored');

      expect(line, isNotNull);
      expect(line!.file, kWindowsUserPathRecord);
      expect(line.line, r'C:\Users\alex\develop\flutter\bin');
      expect(
        system.values[userPath],
        r'%USERPROFILE%\AppData\Local\Microsoft\WindowsApps;'
        r'C:\Users\alex\develop\flutter\bin',
      );
      expect(system.broadcasts, 1);
    });

    test('a directory already there — as written, or expanded — is left alone',
        () async {
      final system = FakeWindowsSystem(values: {
        userPath: r'%USERPROFILE%\develop\flutter\bin',
      });
      final line = await installer(system)
          .addToShellPath(r'c:\users\alex\develop\flutter\bin', 'ignored');
      expect(line, isNull);
      expect(system.values[userPath], r'%USERPROFILE%\develop\flutter\bin');
      expect(system.broadcasts, 0);
    });

    test('uninstall removes exactly the entry recorded, and nothing else',
        () async {
      final system = FakeWindowsSystem(values: {
        userPath: r'C:\mine;C:\Users\alex\develop\flutter\bin;C:\also\mine',
      });
      await installer(system).removeShellLines(const [
        RecordedPathLine(
          file: kWindowsUserPathRecord,
          line: r'C:\Users\alex\develop\flutter\bin',
        ),
      ]);
      expect(system.values[userPath], r'C:\mine;C:\also\mine');
      expect(system.broadcasts, 1);
    });

    test('Windows has no rc file: the registry is the profile', () {
      final profile = ShellProfile.resolve(home: r'C:\Users\a', host: windows);
      expect(profile.isSupported, isTrue);
      expect(profile.path, kWindowsUserPathRecord);
    });
  });

  test('the fresh Path is the machine entries, then the user ones', () {
    final system = FakeWindowsSystem(values: {
      FakeWindowsSystem.keyFor(
          RegistryRoot.localMachine, kMachineEnvironmentKey, 'Path'):
          r'C:\Windows\system32;C:\Program Files\Git\cmd',
      userPath: r'%USERPROFILE%\develop\flutter\bin',
    });
    expect(
      registryPath(system),
      r'C:\Windows\system32;C:\Program Files\Git\cmd;'
      r'C:\Users\alex\develop\flutter\bin',
    );
  });

  group('Git for Windows release', () {
    Map<String, Object?> release({String? digest = 'sha256:ABC123'}) => {
          'tag_name': 'v2.56.0.windows.2',
          'prerelease': false,
          'assets': [
            {
              'name': 'Git-2.56.0.2-64-bit.tar.bz2',
              'browser_download_url': 'https://example.com/a.tar.bz2',
              'digest': 'sha256:000',
              'size': 1,
            },
            {
              'name': 'Git-2.56.0.2-64-bit.exe',
              'browser_download_url': 'https://example.com/Git-64.exe',
              'digest': ?digest,
              'size': 66763664,
            },
            {
              'name': 'Git-2.56.0.2-arm64.exe',
              'browser_download_url': 'https://example.com/Git-arm.exe',
              'digest': 'sha256:def',
              'size': 64316408,
            },
          ],
        };

    test('picks the installer for the CPU, with its digest and size', () {
      final picked =
          pickGitRelease(jsonEncode(release()), arch: 'x64')!;
      expect('${picked.version}', '2.56.0');
      expect(picked.installerUrl.toString(), 'https://example.com/Git-64.exe');
      expect(picked.sha256, 'abc123');
      expect(picked.downloadBytes, 66763664);
      expect(
        pickGitRelease(jsonEncode(release()), arch: 'arm64')!
            .installerUrl
            .toString(),
        'https://example.com/Git-arm.exe',
      );
    });

    test('refuses an installer with nothing to verify it against', () {
      expect(pickGitRelease(jsonEncode(release(digest: null)), arch: 'x64'),
          isNull);
    });

    test('refuses a prerelease', () {
      expect(
        pickGitRelease(
            jsonEncode({...release(), 'prerelease': true}), arch: 'x64'),
        isNull,
      );
    });
  });
}
