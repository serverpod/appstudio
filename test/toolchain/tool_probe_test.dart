import 'dart:convert';
import 'dart:io';

import 'package:appstudio/platform/host_platform.dart';
import 'package:appstudio/toolchain/install_record.dart';
import 'package:appstudio/toolchain/shell_profile.dart';
import 'package:appstudio/toolchain/tool_probe.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/tool_version.dart';
import 'package:appstudio/toolchain/toolchain_manifest.dart';
import 'package:appstudio/toolchain/toolchain_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/toolchain_support.dart';

late ToolManifest manifest;

ToolVersion v(String s) => ToolVersion.tryParse(s)!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    manifest = await loadTestManifest();
  });

  group('version parsers', () {
    test('serverpod', () {
      expect(
        parseServerpodVersion('Serverpod version: 4.0.0-beta.1').toString(),
        '4.0.0-beta.1',
      );
      expect(parseServerpodVersion('dart: command not found'), isNull);
    });

    test('flutter.version.json', () {
      final info = FlutterInfo.parse('''
{
  "frameworkVersion": "3.47.5",
  "channel": "stable",
  "dartSdkVersion": "3.13.4",
  "frameworkRevision": "6a19cca56475dbfba1478ee68d7bd0c2ef891da1"
}
''')!;
      expect(info.frameworkVersion.toString(), '3.47.5');
      expect(info.channel, 'stable');
      expect(info.dartSdkVersion, '3.13.4');
    });

    test('flutter.version.json survives garbage', () {
      expect(FlutterInfo.parse('not json'), isNull);
      expect(FlutterInfo.parse('{}')!.frameworkVersion, isNull);
    });
  });

  group('qualifyFlutter', () {
    FlutterObservation good({String channel = 'stable', String? version}) =>
        FlutterObservation(
          hasFlutterExecutable: true,
          hasDartExecutable: true,
          info: FlutterInfo(
            frameworkVersion: v(version ?? '3.47.5'),
            channel: channel,
          ),
        );

    ({ToolFitness fitness, String? reason}) run(FlutterObservation o) =>
        qualifyFlutter(observation: o, spec: manifest[ToolId.flutter]!);

    test('accepts a stable, in-range SDK', () {
      expect(run(good()).fitness, ToolFitness.satisfied);
    });

    test('accepts a newer stable than any App Studio was built against', () {
      // Fresh installs take the latest stable, and so does `flutter upgrade`.
      expect(run(good(version: '3.52.0')).fitness, ToolFitness.satisfied);
    });

    test('rejects a non-stable channel', () {
      final verdict = run(good(channel: 'beta'));
      expect(verdict.fitness, ToolFitness.wrongVersion);
      expect(verdict.reason, contains('beta'));
    });

    test('rejects an old SDK with a readable reason', () {
      final verdict = run(good(version: '3.41.2'));
      expect(verdict.fitness, ToolFitness.wrongVersion);
      expect(verdict.reason, contains('3.41.2'));
      expect(verdict.reason, contains('>=3.47.0'));
    });

    test('does not need the web artifacts precached', () {
      // Flutter fetches them on the first web build. Rejecting an SDK for not
      // having them yet would send every fresh `flutter` checkout to setup.
      expect(run(good()).fitness, ToolFitness.satisfied);
    });

    test('a missing Dart SDK is incomplete, not missing', () {
      final verdict = run(const FlutterObservation(
        hasFlutterExecutable: true,
        hasDartExecutable: false,
      ));
      expect(verdict.fitness, ToolFitness.incomplete);
    });

    test('absent means notFound', () {
      expect(
        run(const FlutterObservation(
          hasFlutterExecutable: false,
          hasDartExecutable: false,
        )).fitness,
        ToolFitness.notFound,
      );
    });
  });

  group('qualifyVersioned', () {
    ({ToolFitness fitness, String? reason}) run(String? version) =>
        qualifyVersioned(
          exists: true,
          detected: version == null ? null : v(version),
          spec: manifest[ToolId.serverpodCli]!,
        );

    test('accepts a Serverpod CLI inside the range', () {
      expect(run('4.1.0').fitness, ToolFitness.satisfied);
      expect(run('4.9.2').fitness, ToolFitness.satisfied);
    });

    test('rejects one outside it', () {
      // 4.0 has no runner to attach to, and the 4.1 prereleases are
      // superseded by the release.
      expect(run('4.0.3').fitness, ToolFitness.wrongVersion);
      expect(run('4.1.0-beta.3').fitness, ToolFitness.wrongVersion);
      expect(run('5.0.0').fitness, ToolFitness.wrongVersion);
    });

    test('unparseable version output is unusable', () {
      expect(run(null).fitness, ToolFitness.unusable);
    });
  });

  group('flutterAction', () {
    const ours = '/Users/alex/develop/flutter';
    final record = InstallRecord.empty.withTool(RecordedInstall(
      id: ToolId.flutter,
      path: ours,
      installedAt: DateTime.utc(2026),
    ));

    ToolCandidate candidate(String root, ToolFitness fitness) => ToolCandidate(
          id: ToolId.flutter,
          source: ToolSource.host,
          fitness: fitness,
          root: root,
        );

    test('nothing to do when a copy qualifies', () {
      expect(
        flutterAction(
          [candidate('/old', ToolFitness.wrongVersion),
            candidate('/new', ToolFitness.satisfied)],
          InstallRecord.empty,
        ),
        ToolAction.none,
      );
    });

    test('installs when there is none', () {
      expect(flutterAction(const [], InstallRecord.empty), ToolAction.install);
    });

    test('updates an old copy App Studio installed', () {
      expect(
        flutterAction([candidate(ours, ToolFitness.wrongVersion)], record),
        ToolAction.update,
      );
    });

    test('replaces a broken copy App Studio installed', () {
      expect(
        flutterAction([candidate(ours, ToolFitness.incomplete)], record),
        ToolAction.install,
      );
    });

    test('asks the user to update a copy they installed', () {
      // Installing a second SDK beside it would leave the old one first on
      // their PATH.
      expect(
        flutterAction(
          [candidate('/Users/alex/flutter', ToolFitness.wrongVersion)],
          record,
        ),
        ToolAction.manual,
      );
    });
  });

  group('serverpodAction', () {
    test('reinstalls an old copy whoever installed it', () {
      expect(
        serverpodAction(const [
          ToolCandidate(
            id: ToolId.serverpodCli,
            source: ToolSource.host,
            fitness: ToolFitness.wrongVersion,
          ),
        ]),
        ToolAction.update,
      );
      expect(serverpodAction(const []), ToolAction.install);
    });
  });

  group('ToolProbe.inventory', () {
    late Directory tmp;
    late ToolchainPaths paths;
    late String developerDir;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('tool_probe');
      paths = ToolchainPaths.forHome(tmp.path);
      developerDir = p.join(tmp.path, 'CommandLineTools');
    });

    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    Future<void> touch(String path, [String contents = '']) async {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(contents);
    }

    Future<void> fakeFlutter(String root, String version) async {
      await touch(p.join(root, 'bin', paths.host.flutterLauncherName));
      await Directory(p.join(root, 'packages', 'flutter_tools'))
          .create(recursive: true);
      await touch(p.join(
          root, 'bin', 'cache', 'dart-sdk', 'bin', paths.host.dartExecutableName));
      await touch(
        p.join(root, 'bin', 'cache', 'flutter.version.json'),
        jsonEncode({'frameworkVersion': version, 'channel': 'stable'}),
      );
    }

    ToolProbe probe({
      InstallRecord record = InstallRecord.empty,
      bool clt = true,
      String serverpodVersion = '4.1.0',
      String path = '/nonexistent',
      String? loginPath,
      ProcessResult Function(String executable, Map<String, String>? env)?
          flutter,
    }) =>
        ToolProbe(
          paths: paths,
          manifest: manifest,
          record: record,
          environment: {'PATH': path},
          loginShellPath: () async => loginPath,
          runner: (executable, args, {environment}) async {
            if (flutter != null &&
                p.basenameWithoutExtension(executable) == 'flutter') {
              expect(args, ['--version', '--machine']);
              return flutter(executable, environment);
            }
            if (executable == '/usr/bin/xcode-select') {
              return ProcessResult(0, clt ? 0 : 2, clt ? '$developerDir\n' : '',
                  '');
            }
            if (p.basenameWithoutExtension(executable) == 'serverpod') {
              return ProcessResult(
                  0, 0, 'Serverpod version: $serverpodVersion', '');
            }
            throw StateError('unexpected $executable');
          },
        );

    test('a clean Mac needs everything installed', () async {
      final inventory = await probe(clt: false).inventory();

      expect(
        {for (final t in inventory.tools.values) t.id: t.action},
        {
          ToolId.commandLineTools: ToolAction.install,
          ToolId.flutter: ToolAction.install,
          ToolId.serverpodCli: ToolAction.install,
        },
      );
      expect(inventory.legacyInstallFound, isFalse);
    });

    test('finds what App Studio installed and says so', () async {
      await touch(p.join(developerDir, 'usr', 'bin', 'git'));
      await fakeFlutter(paths.flutterInstallDir, '3.47.5');
      final serverpod = p.join(paths.dartInstallBinDir, paths.host.installedExecutableName('serverpod'));
      await touch(serverpod);
      final record = InstallRecord.empty
          .withTool(RecordedInstall(
            id: ToolId.flutter,
            path: paths.flutterInstallDir,
            installedAt: DateTime.utc(2026),
          ))
          .withTool(RecordedInstall(
            id: ToolId.serverpodCli,
            path: serverpod,
            installedAt: DateTime.utc(2026),
          ));

      final inventory = await probe(record: record).inventory();

      expect(inventory.needsSetup, isFalse);
      expect(inventory[ToolId.flutter]!.resolved!.source, ToolSource.appStudio);
      expect(
        inventory[ToolId.serverpodCli]!.resolved!.source,
        ToolSource.appStudio,
      );
      expect(
        inventory[ToolId.commandLineTools]!.resolved!.source,
        ToolSource.host,
      );
    });

    test('a Flutter in a conventional place that App Studio did not install '
        'is the user\'s', () async {
      await touch(p.join(developerDir, 'usr', 'bin', 'git'));
      await fakeFlutter(p.join(tmp.path, 'development', 'flutter'), '3.41.2');

      final inventory = await probe().inventory();

      final flutter = inventory[ToolId.flutter]!;
      expect(flutter.action, ToolAction.manual);
      expect(flutter.bestRejected!.detectedVersion.toString(), '3.41.2');
      expect(inventory.needsManualUpdate, hasLength(1));
    });

    test('an old Serverpod CLI is reinstalled', () async {
      await touch(p.join(paths.dartInstallBinDir, paths.host.installedExecutableName('serverpod')));

      final inventory = await probe(serverpodVersion: '3.4.1').inventory();

      expect(inventory[ToolId.serverpodCli]!.action, ToolAction.update);
    });

    /// An executable at [path] — what `whichOnPath` will find.
    Future<String> executable(String path) async {
      await touch(path, '#!/bin/sh\n');
      if (!Platform.isWindows) await Process.run('/bin/chmod', ['755', path]);
      return path;
    }

    String launcherName(String command) =>
        paths.host.isWindows ? '$command.bat' : command;

    test('a flutter on PATH inside its SDK is read from disk, not run',
        () async {
      final root = p.join(tmp.path, 'sdks', 'flutter');
      await fakeFlutter(root, '3.47.5');
      if (!Platform.isWindows) {
        await Process.run('/bin/chmod', [
          '755',
          p.join(root, 'bin', paths.host.flutterLauncherName),
        ]);
      }

      // The runner throws on any flutter it is asked to run.
      final inventory =
          await probe(path: p.join(root, 'bin')).inventory();

      final resolved = inventory[ToolId.flutter]!.resolved!;
      // Through its symlinks, as `/var` is to `/private/var` on macOS.
      expect(resolved.root, Directory(root).resolveSymbolicLinksSync());
      expect(resolved.launcher, isNull);
      expect(inventory.flutterOnPath, isTrue);
    });

    test('a shim on PATH is asked which SDK it runs', () async {
      final sdk = p.join(tmp.path, 'fvm', 'versions', '3.47.5');
      await fakeFlutter(sdk, '3.47.5');
      final shimDir = p.join(tmp.path, '.fvm_shim');
      final shim = await executable(p.join(shimDir, launcherName('flutter')));
      final fvmDir = p.join(tmp.path, 'homebrew', 'bin');
      await executable(p.join(fvmDir, launcherName('fvm')));
      final sep = paths.host.pathListSeparator;
      final searchPath = '$shimDir$sep$fvmDir';

      String? probedPath;
      final inventory = await probe(
        path: searchPath,
        flutter: (exe, env) {
          probedPath = env?['PATH'];
          // FVM prints notices around the JSON.
          return ProcessResult(0, 0, [
            'FVM: running Flutter 3.47.5',
            '{',
            '  "frameworkVersion": "3.47.5",',
            '  "flutterRoot": ${jsonEncode(sdk)}',
            '}',
            'Done.',
          ].join('\n'), '');
        },
      ).inventory();

      final resolved = inventory[ToolId.flutter]!.resolved!;
      expect(resolved.root, sdk);
      expect(resolved.executable, shim);
      expect(resolved.launcher, shim);
      expect(resolved.launcherPath, searchPath);
      expect(resolved.facts['flutterRoot'], sdk);
      expect(inventory.flutterOnPath, isTrue);
      expect(inventory.flutterWrappers, [FlutterWrapper.fvm]);
      expect(inventory.flutterShimMissing, isFalse);
      // Run without its own folder, so `fvm flutter` with no version set
      // cannot find the shim again and recurse.
      expect(probedPath, fvmDir);
    });

    test('Puro\'s shim keeps its folder, where puro itself is', () async {
      final sdk = p.join(tmp.path, '.puro', 'envs', 'stable', 'flutter');
      await fakeFlutter(sdk, '3.47.5');
      final bin = p.join(tmp.path, '.puro', 'bin');
      await executable(p.join(bin, launcherName('flutter')));
      await executable(p.join(bin, launcherName('puro')));

      String? probedPath;
      final inventory = await probe(
        path: bin,
        flutter: (exe, env) {
          probedPath = env?['PATH'];
          return ProcessResult(
              0, 0, jsonEncode({'flutterRoot': sdk}), '');
        },
      ).inventory();

      // ~/.puro holds a bin/flutter, and is still not taken for a broken SDK.
      expect(inventory[ToolId.flutter]!.resolved!.root, sdk);
      expect(probedPath, bin);
      expect(inventory.flutterWrappers, [FlutterWrapper.puro]);
    });

    test('a shim that reaches no SDK leaves the shim missing', () async {
      final shimDir = p.join(tmp.path, '.fvm_shim');
      await executable(p.join(shimDir, launcherName('flutter')));
      await Directory(p.join(tmp.path, 'fvm')).create();

      final inventory = await probe(
        path: shimDir,
        flutter: (exe, env) =>
            ProcessResult(0, 1, '', 'No Flutter SDK found.'),
      ).inventory();

      expect(inventory[ToolId.flutter]!.isSatisfied, isFalse);
      expect(inventory.flutterOnPath, isFalse);
      expect(inventory.flutterShimMissing, isTrue);
    });

    test('a shim found only by the login shell is run on its PATH', () async {
      // A Finder launch: the inherited PATH has none of the user's tools.
      final sdk = p.join(tmp.path, '.puro', 'envs', 'stable', 'flutter');
      await fakeFlutter(sdk, '3.47.5');
      final bin = p.join(tmp.path, '.puro', 'bin');
      await executable(p.join(bin, launcherName('flutter')));
      await executable(p.join(bin, launcherName('puro')));

      final inventory = await probe(
        loginPath: bin,
        flutter: (exe, env) =>
            ProcessResult(0, 0, jsonEncode({'flutterRoot': sdk}), ''),
      ).inventory();

      expect(inventory[ToolId.flutter]!.resolved!.launcherPath, bin);
    });

    test('FVM\'s folder alone counts as FVM', () async {
      await Directory(p.join(tmp.path, 'fvm', 'versions')).create(
        recursive: true,
      );

      final inventory = await probe().inventory();

      expect(inventory.flutterWrappers, [FlutterWrapper.fvm]);
      expect(inventory.flutterShimMissing, isTrue);
    });

    test('a clean Mac has no version manager, so needs no shim', () async {
      final inventory = await probe(clt: false).inventory();
      expect(inventory.flutterWrappers, isEmpty);
      expect(inventory.flutterShimMissing, isFalse);
    });

    test('the install script\'s Flutter is found', () async {
      await touch(p.join(developerDir, 'usr', 'bin', 'git'));
      await fakeFlutter(paths.installScriptFlutterDir, '3.47.5');

      final inventory = await probe().inventory();

      expect(inventory[ToolId.flutter]!.resolved!.root,
          paths.installScriptFlutterDir);
      expect(inventory[ToolId.flutter]!.resolved!.source, ToolSource.host);
    });

    test('an earlier build\'s private toolchain is found', () async {
      await touch(p.join(paths.legacyToolchainRoot, 'flutter', 'marker'));
      expect((await probe().inventory()).legacyInstallFound, isTrue);
    }, skip: Platform.isMacOS ? false : 'only macOS builds shipped a toolchain');

    test('so is only its PATH block', () async {
      await touch(
        p.join(tmp.path, '.zshrc'),
        '# mine\n\n$kLegacyShellBlockStart\n# x\n$kLegacyShellBlockEnd\n',
      );
      expect((await probe().inventory()).legacyInstallFound, isTrue);
    }, skip: Platform.isMacOS ? false : 'only macOS builds shipped a toolchain');
  });

  group('parseFlutterRoot', () {
    test('reads the machine JSON', () {
      expect(parseFlutterRoot('{"flutterRoot": "/a/flutter"}'), '/a/flutter');
    });

    test('skips notices around it, JSON ones included', () {
      expect(
        parseFlutterRoot([
          '{"notice": "A new version of Puro is available"}',
          'Running Flutter...',
          '{',
          '  "frameworkVersion": "3.47.5",',
          '  "flutterRoot": "/b/flutter"',
          '}',
        ].join('\n')),
        '/b/flutter',
      );
    });

    test('null when nothing names a root', () {
      expect(parseFlutterRoot(''), isNull);
      expect(parseFlutterRoot('No Flutter SDK found.'), isNull);
      expect(parseFlutterRoot('{"frameworkVersion": "3.47.5"}'), isNull);
    });
  });

  group('whichOnPath', () {
    /// A directory with [name] in it, executable unless told otherwise.
    Future<Directory> dirContaining(String name, {bool executable = true}) async {
      final dir = await Directory.systemTemp.createTemp('appstudio_which');
      addTearDown(() => dir.delete(recursive: true));
      final file = File(p.join(dir.path, name));
      await file.writeAsString('#!/bin/sh\n');
      await Process.run('/bin/chmod', [executable ? '755' : '644', file.path]);
      return dir;
    }

    test('takes the first match, so PATH order decides', () async {
      final first = await dirContaining('serverpod');
      final second = await dirContaining('serverpod');
      expect(
        await whichOnPath('serverpod', '${first.path}:${second.path}'),
        p.join(first.path, 'serverpod'),
      );
    });

    test('skips a match it could not execute', () async {
      final dir = await dirContaining('serverpod', executable: false);
      expect(await whichOnPath('serverpod', dir.path), isNull);
    });

    test('returns null with no path to search', () async {
      expect(await whichOnPath('serverpod', null), isNull);
      expect(await whichOnPath('serverpod', ''), isNull);
    });
  }, skip: Platform.isWindows ? 'POSIX execute bits and : separators' : false);

  group('whichOnPath on Windows', () {
    Future<Directory> dirContaining(List<String> names) async {
      final dir = await Directory.systemTemp.createTemp('appstudio_which');
      addTearDown(() => dir.delete(recursive: true));
      for (final name in names) {
        await File(p.join(dir.path, name)).writeAsString('');
      }
      return dir;
    }

    test('finds the PATHEXT name, never the bare shell script', () async {
      // A Flutter SDK's bin holds both `flutter` (for Git Bash) and
      // `flutter.bat`; only the second can be started.
      final dir = await dirContaining(['flutter', 'flutter.bat']);
      expect(
        await whichOnPath('flutter', dir.path, pathExt: '.EXE;.BAT'),
        p.join(dir.path, 'flutter.bat'),
      );
    });

    test('splits PATH on ; so drive letters survive', () async {
      final first = await dirContaining([]);
      final second = await dirContaining(['serverpod.bat']);
      expect(
        await whichOnPath('serverpod', '${first.path};${second.path}'),
        p.join(second.path, 'serverpod.bat'),
      );
    });
  }, skip: Platform.isWindows ? false : 'Windows PATHEXT and ; separators');

  test('pathContainsDir matches whole entries only', () {
    const path = '/usr/bin:/Users/a/develop/flutter/bin/:/bin';
    const mac = HostPlatform.macos;
    expect(
      pathContainsDir(path, '/Users/a/develop/flutter/bin', host: mac),
      isTrue,
    );
    expect(
      pathContainsDir(path, '/Users/a/develop/flutter', host: mac),
      isFalse,
    );
    expect(pathContainsDir(null, '/bin', host: mac), isFalse);
  });

  test('pathContainsDir on Windows splits on ; and ignores case', () {
    const path = r'C:\Windows;C:\Users\a\develop\flutter\bin\;D:\x';
    const windows = HostPlatform.windows;
    expect(
      pathContainsDir(path, r'c:\users\A\develop\flutter\bin', host: windows),
      isTrue,
    );
    expect(pathContainsDir(path, r'C:\Users', host: windows), isFalse);
  });
}
