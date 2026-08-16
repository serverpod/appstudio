import 'dart:io';

import 'package:appstudio/toolchain/tool_probe.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/tool_version.dart';
import 'package:appstudio/toolchain/toolchain_manifest.dart';
import 'package:appstudio/toolchain/toolchain_requirements.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

late ToolManifest manifest;
const requirements = ToolchainRequirements.empty;

ToolVersion v(String s) => ToolVersion.tryParse(s)!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    manifest = ToolManifest.tryParse(
      await File('assets/toolchain_manifest.json').readAsString(),
    )!;
  });

  group('version parsers', () {
    test('git', () {
      expect(parseGitVersion('git version 2.53.0').toString(), '2.53.0');
      // Apple's git appends its own build tag.
      expect(
        parseGitVersion('git version 2.39.5 (Apple Git-154)').toString(),
        '2.39.5',
      );
      expect(parseGitVersion(''), isNull);
      expect(parseGitVersion('command not found'), isNull);
    });

    test('serverpod', () {
      expect(
        parseServerpodVersion('Serverpod version: 4.0.0-beta.1').toString(),
        '4.0.0-beta.1',
      );
      // What is installed on this machine today.
      expect(
        parseServerpodVersion('Serverpod version: 3.5.0-beta.7').toString(),
        '3.5.0-beta.7',
      );
      expect(parseServerpodVersion('dart: command not found'), isNull);
    });

    test('opencode', () {
      expect(parseOpencodeVersion('1.18.4').toString(), '1.18.4');
      expect(parseOpencodeVersion('opencode 1.18.4\n').toString(), '1.18.4');
    });

    test('otool', () {
      expect(
        parseOtoolVersion('Apple LLVM version 17.0.0').toString(),
        '17.0.0',
      );
      expect(
        parseOtoolVersion('llvm-otool\nLLVM version 20.1.0\n').toString(),
        '20.1.0',
      );
    });

    test('flutter.version.json', () {
      final info = FlutterInfo.parse('''
{
  "frameworkVersion": "3.44.2",
  "channel": "stable",
  "dartSdkVersion": "3.12.2",
  "frameworkRevision": "c9a6c484230f8b5e408ec57be1ef71dee1e77020"
}
''')!;
      expect(info.frameworkVersion.toString(), '3.44.2');
      expect(info.channel, 'stable');
      expect(info.dartSdkVersion, '3.12.2');
      expect(info.frameworkRevision, startsWith('c9a6c48'));
    });

    test('flutter.version.json survives garbage', () {
      expect(FlutterInfo.parse('not json'), isNull);
      expect(FlutterInfo.parse('{}')!.frameworkVersion, isNull);
    });
  });

  group('qualifyFlutter', () {
    // In-range means whatever the live manifest pins, so a Flutter bump does
    // not silently turn every fixture here into a wrongVersion.
    String pinned() => manifest[ToolId.flutter]!.version.toString();
    FlutterObservation good({String channel = 'stable', String? version}) =>
        FlutterObservation(
          hasFlutterExecutable: true,
          hasDartExecutable: true,
          hasWebSdk: true,
          info: FlutterInfo(
            frameworkVersion: v(version ?? pinned()),
            channel: channel,
          ),
        );

    ({ToolFitness fitness, String? reason}) run(
      FlutterObservation observation, {
      bool isHost = true,
    }) =>
        qualifyFlutter(
          observation: observation,
          spec: manifest[ToolId.flutter]!,
          requirements: requirements,
          isHost: isHost,
        );

    test('accepts a stable, precached, in-range SDK', () {
      expect(run(good()).fitness, ToolFitness.satisfied);
    });

    test('rejects a host SDK on a non-stable channel', () {
      final verdict = run(good(channel: 'master'));
      expect(verdict.fitness, ToolFitness.wrongVersion);
      expect(verdict.reason, contains('master'));
    });

    test('allows a non-stable channel for an SDK we manage', () {
      // Our own tree is whatever we published; the channel check exists to
      // protect against a developer's master checkout.
      expect(run(good(channel: 'master'), isHost: false).fitness,
          ToolFitness.satisfied);
    });

    test('rejects a version outside the range with a readable reason', () {
      final verdict = run(good(version: '3.38.1'));
      expect(verdict.fitness, ToolFitness.wrongVersion);
      expect(
        verdict.reason,
        '3.38.1 (needs ${manifest[ToolId.flutter]!.hostAccepts})',
      );
    });

    test('rejects an SDK that never precached the web artifacts', () {
      final verdict = run(
        FlutterObservation(
          hasFlutterExecutable: true,
          hasDartExecutable: true,
          hasWebSdk: false,
          info: FlutterInfo(frameworkVersion: v(pinned()), channel: 'stable'),
        ),
      );
      expect(verdict.fitness, ToolFitness.incomplete);
      expect(verdict.reason, contains('precache --web'));
    });

    test('reports a missing Dart SDK as incomplete, not missing', () {
      final verdict = run(
        const FlutterObservation(
          hasFlutterExecutable: true,
          hasDartExecutable: false,
          hasWebSdk: true,
        ),
      );
      expect(verdict.fitness, ToolFitness.incomplete);
    });

    test('absent means notFound', () {
      final verdict = run(
        const FlutterObservation(
          hasFlutterExecutable: false,
          hasDartExecutable: false,
          hasWebSdk: false,
        ),
      );
      expect(verdict.fitness, ToolFitness.notFound);
    });

    test('unreadable version is unusable, not silently accepted', () {
      final verdict = run(
        const FlutterObservation(
          hasFlutterExecutable: true,
          hasDartExecutable: true,
          hasWebSdk: true,
        ),
      );
      expect(verdict.fitness, ToolFitness.unusable);
    });
  });

  group('qualifyVersioned', () {
    ({ToolFitness fitness, String? reason}) run({
      bool exists = true,
      bool isStub = false,
      String? detected,
      String? incompleteReason,
      ToolId id = ToolId.serverpodCli,
    }) =>
        qualifyVersioned(
          exists: exists,
          isStub: isStub,
          detected: detected == null ? null : v(detected),
          spec: manifest[id]!,
          requirements: requirements,
          incompleteReason: incompleteReason,
        );

    test('accepts the pinned Serverpod', () {
      expect(run(detected: '4.0.0-beta.2').fitness, ToolFitness.satisfied);
    });

    test('rejects the host Serverpod that is actually installed here', () {
      final verdict = run(detected: '3.5.0-beta.7');
      expect(verdict.fitness, ToolFitness.wrongVersion);
      expect(verdict.reason, '3.5.0-beta.7 (needs >=4.0.0-beta.2 <4.1.0)');
    });

    test('a CLT shim is flagged, never run', () {
      final verdict = run(isStub: true, id: ToolId.git);
      expect(verdict.fitness, ToolFitness.stub);
      expect(verdict.reason, 'Xcode Command Line Tools stub');
    });

    test('missing native libraries read as incomplete', () {
      final verdict = run(
        detected: '4.0.0-beta.2',
        incompleteReason: 'native libraries (lib/) are missing',
      );
      expect(verdict.fitness, ToolFitness.incomplete);
      expect(verdict.reason, contains('lib/'));
    });

    test('unparseable version output is unusable', () {
      expect(run(detected: null).fitness, ToolFitness.unusable);
    });

    test('absent is notFound', () {
      expect(run(exists: false).fitness, ToolFitness.notFound);
    });

    test('git accepts anything modern, including a dugite revision', () {
      expect(run(detected: '2.53.0', id: ToolId.git).fitness,
          ToolFitness.satisfied);
      expect(run(detected: '2.53.0-3', id: ToolId.git).fitness,
          ToolFitness.satisfied);
      expect(run(detected: '2.10.0', id: ToolId.git).fitness,
          ToolFitness.wrongVersion);
    });
  });

  group('isMachO', () {
    test('accepts a real binary', () async {
      // codesign is a genuine base-system Mach-O on every Mac.
      expect(await isMachO('/usr/bin/codesign'), isTrue);
    });

    test('rejects a text file', () async {
      final dir = await Directory.systemTemp.createTemp('appstudio_macho');
      addTearDown(() => dir.delete(recursive: true));
      final script = File('${dir.path}/fake');
      await script.writeAsString('#!/bin/sh\necho hi\n');
      expect(await isMachO(script.path), isFalse);
    });

    test('rejects a missing or empty file', () async {
      final dir = await Directory.systemTemp.createTemp('appstudio_macho');
      addTearDown(() => dir.delete(recursive: true));
      final empty = File('${dir.path}/empty');
      await empty.writeAsBytes(const []);
      expect(await isMachO(empty.path), isFalse);
      expect(await isMachO('${dir.path}/nope'), isFalse);
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

    test('finds an executable on the path', () async {
      final dir = await dirContaining('serverpod');
      expect(
        await whichOnPath('serverpod', dir.path),
        p.join(dir.path, 'serverpod'),
      );
    });

    test('takes the first match, so PATH order decides', () async {
      // This is the whole bug: a stale ~/.pub-cache/bin/serverpod was the only
      // candidate the probe ever saw, while the `dart install` copy earlier on
      // PATH — the one the user's shell runs — was invisible.
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

    test('skips directories that do not have it, and empty entries', () async {
      final dir = await dirContaining('serverpod');
      expect(
        await whichOnPath('serverpod', '/nonexistent::${dir.path}'),
        p.join(dir.path, 'serverpod'),
      );
    });

    test('returns null with no path to search', () async {
      // The old implementation shelled out to `which`, which the probe ran with
      // no environment at all — so this was the answer for *every* lookup.
      expect(await whichOnPath('serverpod', null), isNull);
      expect(await whichOnPath('serverpod', ''), isNull);
    });

    test('resolves a symlink into bin, which is how dart install ships',
        () async {
      final target = await dirContaining('serverpod-real');
      final linkDir = await Directory.systemTemp.createTemp('appstudio_link');
      addTearDown(() => linkDir.delete(recursive: true));
      await Link(p.join(linkDir.path, 'serverpod'))
          .create(p.join(target.path, 'serverpod-real'));

      expect(
        await whichOnPath('serverpod', linkDir.path),
        p.join(linkDir.path, 'serverpod'),
      );
    });
  });
}
