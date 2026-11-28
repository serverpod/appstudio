import 'dart:io';

import 'package:appstudio/platform/host_platform.dart';
import 'package:appstudio/toolchain/install_plan.dart';
import 'package:appstudio/toolchain/install_record.dart';
import 'package:appstudio/toolchain/linux_packages.dart';
import 'package:appstudio/toolchain/tool_probe.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/tool_version.dart';
import 'package:appstudio/toolchain/toolchain_manifest.dart';
import 'package:appstudio/toolchain/toolchain_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/toolchain_support.dart';

/// The Linux toolchain: which tools, the system packages App Studio checks for
/// but never installs, and where Flutter and `dart install` put things.
void main() {
  const linux = HostPlatform.linux;

  group('the tool set', () {
    test('Linux checks the system packages before Flutter', () {
      expect(ToolId.requiredOn(linux), [
        ToolId.systemPackages,
        ToolId.flutter,
        ToolId.serverpodCli,
      ]);
    });

    test('the system packages are Linux\'s alone', () async {
      final source = await loadTestManifestSource();
      final onLinux = ToolManifest.tryParse(source, host: linux)!;
      expect(onLinux.tools.keys, ToolId.requiredOn(linux));
      for (final other in [HostPlatform.macos, HostPlatform.windows]) {
        final manifest = ToolManifest.tryParse(source, host: other)!;
        expect(manifest[ToolId.systemPackages], isNull, reason: '$other');
      }
    });
  });

  group('the distro\'s install command', () {
    const ubuntu = 'NAME="Ubuntu"\nID=ubuntu\nID_LIKE=debian\n';
    const omarchy = 'NAME="Omarchy"\nID=omarchy\nID_LIKE=arch\n';
    const fedora = 'NAME="Fedora Linux"\nID=fedora\n';
    const tumbleweed =
        'NAME="openSUSE Tumbleweed"\nID="opensuse-tumbleweed"\n'
        'ID_LIKE="opensuse suse"\n';

    test('is found from ID, then ID_LIKE', () {
      expect(packageManagerFor(ubuntu), LinuxPackageManager.apt);
      expect(packageManagerFor(omarchy), LinuxPackageManager.pacman);
      expect(packageManagerFor(fedora), LinuxPackageManager.dnf);
      expect(packageManagerFor(tumbleweed), LinuxPackageManager.zypper);
      expect(packageManagerFor('ID=nixos\n'), isNull);
    });

    test('names Debian\'s xz package as Debian does', () {
      expect(
        linuxInstallCommand(['curl', 'xz'], LinuxPackageManager.apt),
        'sudo apt install curl xz-utils',
      );
      expect(
        linuxInstallCommand(['curl', 'xz'], LinuxPackageManager.pacman),
        'sudo pacman -S --needed curl xz',
      );
    });

    test('is not guessed for a distro App Studio does not know', () {
      expect(linuxInstallCommand(['curl'], null), isNull);
    });

    test('os-release quoting is stripped', () {
      expect(parseOsRelease(tumbleweed)['ID'], 'opensuse-tumbleweed');
      expect(parseOsRelease("ID='x'\n# c\n\nBAD\n"), {'ID': 'x'});
    });
  });

  group('probing the system packages', () {
    late Directory tmp;
    late String bin;
    late String osRelease;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('linux_probe');
      bin = p.join(tmp.path, 'bin');
      await Directory(bin).create();
      osRelease = p.join(tmp.path, 'os-release');
      await File(osRelease).writeAsString('ID=ubuntu\nID_LIKE=debian\n');
    });

    tearDown(() => tmp.delete(recursive: true));

    /// An executable named [name] on the probe's PATH: a link to a real one,
    /// so it carries the execute bits `whichOnPath` checks for.
    Future<void> provide(String name) =>
        Link(p.join(bin, name)).create(Platform.resolvedExecutable);

    Future<ToolStatus> probe() async {
      final manifest =
          ToolManifest.tryParse(await loadTestManifestSource(), host: linux)!;
      final inventory = await ToolProbe(
        paths: ToolchainPaths.forHome(p.join(tmp.path, 'home'), host: linux),
        manifest: manifest,
        record: InstallRecord.empty,
        osReleasePath: osRelease,
        sandbox: ProbeSandbox(
          runner: (executable, arguments, {environment}) async =>
              ProcessResult(0, 1, '', ''),
          loginShellPath: () async => null,
          environment: {'PATH': bin},
        ),
      ).inventory();
      return inventory[ToolId.systemPackages]!;
    }

    test('all four on PATH is satisfied', () async {
      for (final name in kLinuxRequiredCommands) {
        await provide(name);
      }
      final status = await probe();
      expect(status.isSatisfied, isTrue);
      expect(status.action, ToolAction.none);
    });

    test('a missing one is the user\'s to install, with the distro\'s command',
        () async {
      await provide('git');
      await provide('unzip');
      final status = await probe();
      expect(status.isSatisfied, isFalse);
      // Never automatic: it needs sudo, which App Studio never runs.
      expect(status.action, ToolAction.manual);
      final facts = status.bestRejected!.facts;
      expect(facts['missing'], 'curl xz');
      expect(facts['installCommand'], 'sudo apt install curl xz-utils');
    });

    test('an unknown distro gets the package names, not a guessed command',
        () async {
      await File(osRelease).writeAsString('ID=nixos\n');
      final status = await probe();
      final facts = status.bestRejected!.facts;
      expect(facts['installCommand'], isNull);
      expect(facts['packages'], 'git curl unzip xz');
    });

    test('setup waits on them', () async {
      final manifest =
          ToolManifest.tryParse(await loadTestManifestSource(), host: linux)!;
      final status = await probe();
      final inventory = ToolchainInventory(
        manifest: manifest,
        tools: {ToolId.systemPackages: status},
      );
      expect(inventory.needsManualUpdate, [status]);
      expect(inventory.needsSetup, isTrue);
      expect(inventory.installable, isEmpty);
    });
  }, skip: Platform.isWindows ? 'needs POSIX executables' : false);

  group('where things go', () {
    final paths = ToolchainPaths.forHome('/home/alex', host: linux);

    test('Flutter goes where Flutter\'s Linux instructions extract it', () {
      expect(paths.flutterInstallDir, '/home/alex/develop/flutter');
    });

    test('dart install puts executables in ~/.local/state/Dart', () {
      expect(
        paths.dartInstallBinDir,
        '/home/alex/.local/state/Dart/install/bin',
      );
    });

    test('XDG_STATE_HOME moves them', () {
      final moved = ToolchainPaths.forHome(
        '/home/alex',
        host: linux,
        environment: const {'XDG_STATE_HOME': '/state/alex'},
      );
      expect(moved.dartInstallBinDir, '/state/alex/Dart/install/bin');
    });

    test('Flutter comes from the Linux feed, which serves .tar.xz', () {
      expect(
        flutterReleasesUrlFor(HostOs.linux).path,
        endsWith('/releases_linux.json'),
      );
      const feed = '''
{
  "base_url": "https://storage.googleapis.com/flutter_infra_release/releases",
  "releases": [
    {
      "channel": "stable",
      "version": "3.50.1",
      "dart_sdk_arch": "x64",
      "archive": "stable/linux/flutter_linux_3.50.1-stable.tar.xz",
      "sha256": "AB12"
    }
  ]
}''';
      final release = pickFlutterRelease(
        feed,
        accepts: VersionRange.tryParse('>=3.47.0')!,
        arch: 'x64',
      )!;
      expect(release.archiveUrl.path, endsWith('.tar.xz'));
      expect(release.sha256, 'ab12');
    });
  });
}
