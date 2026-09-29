import 'dart:convert';
import 'dart:io';

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
      expect(run('4.0.3').fitness, ToolFitness.satisfied);
    });

    test('rejects one outside it', () {
      expect(run('3.4.1').fitness, ToolFitness.wrongVersion);
      expect(run('4.1.0').fitness, ToolFitness.wrongVersion);
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
      await touch(p.join(root, 'bin', 'flutter'));
      await touch(p.join(root, 'bin', 'cache', 'dart-sdk', 'bin', 'dart'));
      await touch(
        p.join(root, 'bin', 'cache', 'flutter.version.json'),
        jsonEncode({'frameworkVersion': version, 'channel': 'stable'}),
      );
    }

    ToolProbe probe({
      InstallRecord record = InstallRecord.empty,
      bool clt = true,
      String serverpodVersion = '4.0.3',
    }) =>
        ToolProbe(
          paths: paths,
          manifest: manifest,
          record: record,
          environment: {'PATH': '/nonexistent'},
          loginShellPath: () async => null,
          runner: (executable, args, {environment}) async {
            if (executable == '/usr/bin/xcode-select') {
              return ProcessResult(0, clt ? 0 : 2, clt ? '$developerDir\n' : '',
                  '');
            }
            if (p.basename(executable) == 'serverpod') {
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
      final serverpod = p.join(paths.dartInstallBinDir, 'serverpod');
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
      await touch(p.join(paths.dartInstallBinDir, 'serverpod'));

      final inventory = await probe(serverpodVersion: '3.4.1').inventory();

      expect(inventory[ToolId.serverpodCli]!.action, ToolAction.update);
    });

    test('an earlier build\'s private toolchain is found', () async {
      await touch(p.join(paths.legacyToolchainRoot, 'flutter', 'marker'));
      expect((await probe().inventory()).legacyInstallFound, isTrue);
    });

    test('so is only its PATH block', () async {
      await touch(
        p.join(tmp.path, '.zshrc'),
        '# mine\n\n$kLegacyShellBlockStart\n# x\n$kLegacyShellBlockEnd\n',
      );
      expect((await probe().inventory()).legacyInstallFound, isTrue);
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
  });

  test('pathContainsDir matches whole entries only', () {
    const path = '/usr/bin:/Users/a/develop/flutter/bin/:/bin';
    expect(pathContainsDir(path, '/Users/a/develop/flutter/bin'), isTrue);
    expect(pathContainsDir(path, '/Users/a/develop/flutter'), isFalse);
    expect(pathContainsDir(null, '/bin'), isFalse);
  });
}
