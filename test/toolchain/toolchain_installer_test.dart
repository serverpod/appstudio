import 'dart:io';

import 'package:appstudio/toolchain/install_plan.dart';
import 'package:appstudio/toolchain/install_record.dart';
import 'package:appstudio/toolchain/shell_profile.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/tool_version.dart';
import 'package:appstudio/toolchain/toolchain_installer.dart';
import 'package:appstudio/toolchain/toolchain_paths.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

/// Everything here runs against a scratch home: the installer writes to
/// `~/develop`, `~/.zprofile` and `~/Library`, and a test that reached the
/// real ones would edit the machine running it.
void main() {
  late Directory tmp;
  late ToolchainPaths paths;
  late String zprofile;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('installer');
    paths = ToolchainPaths.forHome(tmp.path);
    zprofile = p.join(tmp.path, '.zprofile');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  ToolchainInstaller installer({
    http.Client? client,
    String? loginPath,
    bool supportedShell = true,
  }) =>
      ToolchainInstaller(
        paths: paths,
        httpClient: client ?? MockClient((_) async => http.Response('', 404)),
        loginShellPath: () async => loginPath,
        profile: ShellProfile(
          shell: supportedShell ? 'zsh' : 'fish',
          path: supportedShell ? zprofile : null,
        ),
      );

  /// A zip laid out like the official archive: one top-level `flutter/`.
  Future<List<int>> flutterZip() async {
    final src = Directory(p.join(tmp.path, 'zipsrc'));
    final bin = File(p.join(src.path, 'flutter', 'bin', 'flutter'));
    await bin.parent.create(recursive: true);
    await bin.writeAsString('#!/bin/sh\necho flutter\n');
    await Process.run('/bin/chmod', ['755', bin.path]);
    final zip = p.join(tmp.path, 'flutter.zip');
    final result = await Process.run(
      '/usr/bin/zip',
      ['-qry', zip, 'flutter'],
      workingDirectory: src.path,
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    await src.delete(recursive: true);
    final bytes = await File(zip).readAsBytes();
    await File(zip).delete();
    return bytes;
  }

  FlutterRelease releaseFor(List<int> bytes, {String? sha}) => FlutterRelease(
        version: ToolVersion.tryParse('3.47.5')!,
        archiveUrl: Uri.parse('https://example.invalid/flutter.zip'),
        sha256: sha ?? sha256.convert(bytes).toString(),
        downloadBytes: bytes.length,
      );

  http.Client serving(List<int> bytes) =>
      MockClient((_) async => http.Response.bytes(bytes, 200));

  group('installFlutter', () {
    test('unpacks the official archive into ~/develop/flutter', () async {
      final bytes = await flutterZip();

      final entry = await installer(client: serving(bytes)).installFlutter(
        releaseFor(bytes),
        onProgress: (_) {},
        cancel: CancelToken(),
      );

      expect(entry.path, p.join(tmp.path, 'develop', 'flutter'));
      expect(entry.version, '3.47.5');
      final flutter = File(p.join(entry.path!, 'bin', 'flutter'));
      expect(await flutter.exists(), isTrue);
      // unzip keeps the exec bit the SDK's scripts need.
      expect((await flutter.stat()).mode & 0x49, isNonZero);
      // Neither the archive nor the staging directory is left behind.
      expect(await Directory(paths.downloadsDir).list().isEmpty, isTrue);
      expect(
        await Directory(p.join(tmp.path, 'develop')).list().map((e) => p.basename(e.path)).toList(),
        ['flutter'],
      );
    });

    test('refuses a download whose checksum does not match', () async {
      final bytes = await flutterZip();

      await expectLater(
        installer(client: serving(bytes)).installFlutter(
          releaseFor(bytes, sha: 'f' * 64),
          onProgress: (_) {},
          cancel: CancelToken(),
        ),
        throwsA(isA<ToolInstallException>()),
      );
      expect(await Directory(paths.flutterInstallDir).exists(), isFalse);
    });

    test('never overwrites a folder the user put there', () async {
      final theirs = File(p.join(paths.flutterInstallDir, 'notes.txt'));
      await theirs.parent.create(recursive: true);
      await theirs.writeAsString('mine');
      final bytes = await flutterZip();

      await expectLater(
        installer(client: serving(bytes)).installFlutter(
          releaseFor(bytes),
          onProgress: (_) {},
          cancel: CancelToken(),
        ),
        throwsA(isA<ToolInstallException>().having(
          (e) => e.message,
          'message',
          contains('~/develop/flutter already exists'),
        )),
      );
      expect(await theirs.readAsString(), 'mine');
    });

    test('replaces a copy App Studio installed there itself', () async {
      final old = File(p.join(paths.flutterInstallDir, 'old-marker'));
      await old.parent.create(recursive: true);
      await old.writeAsString('old');
      final bytes = await flutterZip();

      await installer(client: serving(bytes)).installFlutter(
        releaseFor(bytes),
        onProgress: (_) {},
        cancel: CancelToken(),
        owned: RecordedInstall(
          id: ToolId.flutter,
          path: paths.flutterInstallDir,
          installedAt: DateTime.utc(2026),
        ),
      );

      expect(await old.exists(), isFalse);
      expect(
        await File(p.join(paths.flutterInstallDir, 'bin', 'flutter')).exists(),
        isTrue,
      );
    });

    test('a cancelled download installs nothing', () async {
      final bytes = await flutterZip();
      final cancel = CancelToken()..cancel();

      await expectLater(
        installer(client: serving(bytes)).installFlutter(
          releaseFor(bytes),
          onProgress: (_) {},
          cancel: cancel,
        ),
        throwsA(isA<InstallCancelled>()),
      );
      expect(await Directory(paths.flutterInstallDir).exists(), isFalse);
    });
  });

  group('addToShellPath', () {
    const dir = '/Users/alex/develop/flutter/bin';
    const line = r'export PATH="$HOME/develop/flutter/bin:$PATH"';

    test('writes the line and returns it for the record', () async {
      final written = await installer().addToShellPath(dir, line);

      expect(written, RecordedPathLine(file: zprofile, line: line));
      expect(await File(zprofile).readAsString(), '$line\n');
    });

    test('writes nothing when the shell already has the directory', () async {
      // Someone already set this up; a second line would be clutter, and
      // recording it would have uninstall remove a line that is not ours.
      final written = await installer(loginPath: '/usr/bin:$dir')
          .addToShellPath(dir, line);

      expect(written, isNull);
      expect(await File(zprofile).exists(), isFalse);
    });

    test('writes nothing for a shell it cannot edit', () async {
      expect(
        await installer(supportedShell: false).addToShellPath(dir, line),
        isNull,
      );
    });
  });

  group('uninstall', () {
    test('Flutter goes with exactly its own line', () async {
      final root = Directory(paths.flutterInstallDir);
      await root.create(recursive: true);
      const line = r'export PATH="$HOME/develop/flutter/bin:$PATH"';
      await File(zprofile).writeAsString('# mine\n$line\nexport FOO=1\n');

      await installer().uninstallFlutter(RecordedInstall(
        id: ToolId.flutter,
        path: root.path,
        installedAt: DateTime.utc(2026),
        pathLines: [RecordedPathLine(file: zprofile, line: line)],
      ));

      expect(await root.exists(), isFalse);
      expect(await File(zprofile).readAsString(), '# mine\nexport FOO=1\n');
    });

    test('the dart install PATH line stays while other tools use it', () async {
      final bin = Directory(paths.dartInstallBinDir);
      await bin.create(recursive: true);
      final serverpod = File(p.join(bin.path, 'serverpod'));
      await serverpod.writeAsString('');
      await File(p.join(bin.path, 'other_tool')).writeAsString('');
      final line = dartInstallPathLine(bin.path, home: tmp.path);
      await File(zprofile).writeAsString('$line\n');

      await installer().uninstallServerpod(RecordedInstall(
        id: ToolId.serverpodCli,
        path: serverpod.path,
        installedAt: DateTime.utc(2026),
        pathLines: [RecordedPathLine(file: zprofile, line: line)],
      ));

      expect(await serverpod.exists(), isFalse);
      expect(await File(zprofile).readAsString(), '$line\n');
    });

    test('and goes once nothing does', () async {
      final bin = Directory(paths.dartInstallBinDir);
      await bin.create(recursive: true);
      final serverpod = File(p.join(bin.path, 'serverpod'));
      await serverpod.writeAsString('');
      final line = dartInstallPathLine(bin.path, home: tmp.path);
      await File(zprofile).writeAsString('# mine\n$line\n');

      await installer().uninstallServerpod(RecordedInstall(
        id: ToolId.serverpodCli,
        path: serverpod.path,
        installedAt: DateTime.utc(2026),
        pathLines: [RecordedPathLine(file: zprofile, line: line)],
      ));

      expect(await File(zprofile).readAsString(), '# mine\n');
    });
  });

  group('removeLegacyInstall', () {
    test('removes the private toolchain, its shims and the PATH block, and '
        'nothing else', () async {
      for (final dir in paths.legacyPaths) {
        await Directory(p.join(dir, 'x')).create(recursive: true);
      }
      final scratch = Directory(p.join(paths.appSupportRoot, 'agent-scratch'));
      await scratch.create(recursive: true);
      final zshrc = File(p.join(tmp.path, '.zshrc'));
      await zshrc.writeAsString(
        '# mine\n\n$kLegacyShellBlockStart\n# checksum: x\n'
        'export PATH="${paths.legacyShimDir}:\$PATH"\n$kLegacyShellBlockEnd\n',
      );

      await installer().removeLegacyInstall();

      for (final dir in paths.legacyPaths) {
        expect(await Directory(dir).exists(), isFalse, reason: dir);
      }
      expect(await scratch.exists(), isTrue);
      expect(await zshrc.readAsString(), '# mine\n');
    });
  });

  test('collectGarbage clears a crashed unpack', () async {
    final staging =
        Directory(p.join(tmp.path, 'develop', '.flutter-install-123'));
    await staging.create(recursive: true);

    await installer().collectGarbage();

    expect(await staging.exists(), isFalse);
  });
}
