import 'dart:convert';
import 'dart:io';

import 'package:appstudio/toolchain/install_progress.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/toolchain_installer.dart';
import 'package:appstudio/toolchain/platform_key.dart';
import 'package:appstudio/toolchain/toolchain_manifest.dart';
import 'package:appstudio/toolchain/toolchain_paths.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// Serves one tarball on loopback, with switches for the failure modes that
/// matter: a server that ignores Range, and one that corrupts the body.
class _ArtifactServer {
  _ArtifactServer(this._bytes);

  final List<int> _bytes;
  late HttpServer _server;

  bool honourRange = true;
  bool corrupt = false;

  /// Requests seen, for asserting a resume actually resumed.
  final List<String?> rangeHeaders = [];

  Uri get url => Uri.parse('http://127.0.0.1:${_server.port}/tool.tar.gz');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      final range = request.headers.value(HttpHeaders.rangeHeader);
      rangeHeaders.add(range);

      var body = corrupt ? _corrupted() : _bytes;
      var status = HttpStatus.ok;

      if (range != null && honourRange) {
        final start = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
        if (start >= body.length) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          await request.response.close();
          return;
        }
        body = body.sublist(start);
        status = HttpStatus.partialContent;
      }

      request.response.statusCode = status;
      request.response.headers.contentType =
          ContentType('application', 'gzip');
      request.response.add(body);
      await request.response.close();
    });
  }

  List<int> _corrupted() {
    final copy = [..._bytes];
    copy[copy.length ~/ 2] ^= 0xFF;
    return copy;
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late ToolchainPaths paths;
  late List<int> archiveBytes;
  late String archiveSha;
  late _ArtifactServer server;

  setUp(() async {
    // The Flutter test binding installs an HttpOverrides that fails every
    // request, to stop tests hitting the network. This test serves its own
    // artifact on loopback, so restore the real client.
    HttpOverrides.global = null;

    temp = await Directory.systemTemp.createTemp('appstudio_installer');
    paths = ToolchainPaths(temp.path);

    // Build a real tarball with one top-level dir, exactly like publish does.
    final source = Directory('${temp.path}/src/opencode-1.18.4');
    await Directory('${source.path}/nested').create(recursive: true);
    await File('${source.path}/opencode').writeAsString('#!/bin/sh\necho hi\n');
    await File('${source.path}/nested/data.txt').writeAsString('payload');

    final tarPath = '${temp.path}/artifact.tar.gz';
    final result = await Process.run('/usr/bin/tar', [
      '--no-mac-metadata',
      '-czf',
      tarPath,
      '-C',
      '${temp.path}/src',
      'opencode-1.18.4',
    ]);
    expect(result.exitCode, 0, reason: '${result.stderr}');

    archiveBytes = await File(tarPath).readAsBytes();
    archiveSha = sha256.convert(archiveBytes).toString();

    server = _ArtifactServer(archiveBytes);
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    // uninstall/uninstallAll rename first and delete in the background on
    // purpose, so the UI is correct immediately. That can still be in flight
    // here — a vanished temp dir is expected, not a failure.
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } on FileSystemException {
      // Concurrent background cleanup got there first.
    }
  });

  /// A manifest whose single tool points at the loopback server.
  ToolManifest manifestFor({String? sha, int? downloadBytes}) {
    return ToolManifest.tryParse(jsonEncode({
      'schemaVersion': 1,
      'manifestId': 'test',
      'baseUrl': '${server.url.origin}/',
      'tools': [
        {
          'id': 'opencode',
          'displayName': 'OpenCode',
          'version': '1.18.4',
          'build': 1,
          'hostAccepts': '>=1.0.0',
          'required': true,
          'installDir': 'opencode/1.18.4',
          'platforms': {
            currentPlatformKey(): {
              'path': 'tool.tar.gz',
              'sha256': sha ?? archiveSha,
              'downloadBytes': downloadBytes ?? archiveBytes.length,
              'installedBytes': 1024,
              'format': 'tar.gz',
              'stripComponents': 1,
            },
          },
          'entrypoints': {'opencode': 'opencode'},
          'metadata': const <String, dynamic>{},
        },
      ],
    }))!;
  }

  ToolchainInstaller installerFor(ToolManifest manifest) {
    final installer = ToolchainInstaller(paths: paths, manifest: manifest);
    addTearDown(installer.close);
    return installer;
  }

  Future<List<ToolProgress>> runInstall(
    ToolchainInstaller installer,
    ToolSpec spec, {
    CancelToken? cancel,
  }) async {
    final seen = <ToolProgress>[];
    await installer.install(
      spec,
      cancel: cancel,
      onProgress: seen.add,
    );
    return seen;
  }

  String installedDir() => '${paths.toolchainRoot}/opencode/1.18.4';

  test('installs, stripping the top-level directory', () async {
    final manifest = manifestFor();
    await runInstall(installerFor(manifest), manifest[ToolId.opencode]!);

    expect(File('${installedDir()}/opencode').existsSync(), isTrue);
    expect(File('${installedDir()}/nested/data.txt').readAsStringSync(), 'payload');
    // The archive's own top-level directory must not survive.
    expect(Directory('${installedDir()}/opencode-1.18.4').existsSync(), isFalse);
  });

  test('records what it installed', () async {
    final manifest = manifestFor();
    await runInstall(installerFor(manifest), manifest[ToolId.opencode]!);

    final installed = jsonDecode(
      File(paths.installedFile).readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(installed['opencode']['version'], '1.18.4');
    expect(installed['opencode']['sha256'], archiveSha);
  });

  test('reports progress through to done', () async {
    final manifest = manifestFor();
    final seen = await runInstall(installerFor(manifest), manifest[ToolId.opencode]!);

    final phases = seen.map((p) => p.phase).toSet();
    expect(phases, contains(ToolPhase.downloading));
    expect(phases, contains(ToolPhase.verifying));
    expect(phases, contains(ToolPhase.extracting));
    expect(seen.last.phase, ToolPhase.done);
  });

  test('a hash mismatch installs nothing', () async {
    final manifest = manifestFor(sha: 'a' * 64);
    final installer = installerFor(manifest);

    await expectLater(
      installer.install(
        manifest[ToolId.opencode]!,
        onProgress: (_) {},
      ),
      throwsA(isA<ToolInstallException>()),
    );

    // Nothing installed, and the bad archive is gone rather than retried.
    expect(Directory(installedDir()).existsSync(), isFalse);
    expect(
      Directory(paths.downloadsDir).listSync().where(
            (e) => e.path.endsWith('.tar.gz'),
          ),
      isEmpty,
    );
  });

  test('a corrupted body is caught by verification, not extracted', () async {
    server.corrupt = true;
    final manifest = manifestFor();
    final installer = installerFor(manifest);

    await expectLater(
      installer.install(manifest[ToolId.opencode]!, onProgress: (_) {}),
      throwsA(
        isA<ToolInstallException>().having(
          (e) => e.message,
          'message',
          contains('corrupted'),
        ),
      ),
    );
    expect(Directory(installedDir()).existsSync(), isFalse);
  });

  test('resumes from a partial download', () async {
    // Leave a half-written .part behind, as a killed app would.
    await Directory(paths.downloadsDir).create(recursive: true);
    final part = File('${paths.downloadsDir}/opencode-1.18.4.tar.gz.part');
    await part.writeAsBytes(archiveBytes.sublist(0, archiveBytes.length ~/ 2));

    final manifest = manifestFor();
    await runInstall(installerFor(manifest), manifest[ToolId.opencode]!);

    expect(server.rangeHeaders.single, isNotNull,
        reason: 'should have sent a Range header');
    expect(File('${installedDir()}/opencode').existsSync(), isTrue);
  });

  test('restarts cleanly when the server ignores Range', () async {
    server.honourRange = false;
    await Directory(paths.downloadsDir).create(recursive: true);
    final part = File('${paths.downloadsDir}/opencode-1.18.4.tar.gz.part');
    await part.writeAsBytes(archiveBytes.sublist(0, archiveBytes.length ~/ 2));

    final manifest = manifestFor();
    await runInstall(installerFor(manifest), manifest[ToolId.opencode]!);

    // A 200 must truncate, not append — otherwise the hash would fail.
    expect(File('${installedDir()}/opencode').existsSync(), isTrue);
  });

  test('an upgrade replaces the tree without leaving the old one', () async {
    final manifest = manifestFor();
    final spec = manifest[ToolId.opencode]!;
    await runInstall(installerFor(manifest), spec);

    await File('${installedDir()}/stale.txt').writeAsString('old');
    await runInstall(installerFor(manifest), spec);

    expect(File('${installedDir()}/opencode').existsSync(), isTrue);
    expect(File('${installedDir()}/stale.txt').existsSync(), isFalse,
        reason: 'the swap must replace, not merge');
  });

  test('cancelling leaves nothing installed', () async {
    final manifest = manifestFor();
    final installer = installerFor(manifest);
    final cancel = CancelToken()..cancel();

    await expectLater(
      installer.install(
        manifest[ToolId.opencode]!,
        cancel: cancel,
        onProgress: (_) {},
      ),
      throwsA(anything),
    );
    expect(Directory(installedDir()).existsSync(), isFalse);
  });

  test('uninstall removes the managed tree', () async {
    final manifest = manifestFor();
    final spec = manifest[ToolId.opencode]!;
    final installer = installerFor(manifest);
    await runInstall(installer, spec);
    expect(Directory(installedDir()).existsSync(), isTrue);

    await installer.uninstall(spec);
    expect(Directory(installedDir()).existsSync(), isFalse);

    final installed = jsonDecode(
      File(paths.installedFile).readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(installed.containsKey('opencode'), isFalse);
  });

  test('uninstallAll clears the toolchain root only', () async {
    final manifest = manifestFor();
    await runInstall(installerFor(manifest), manifest[ToolId.opencode]!);

    // Something outside toolchain/ that must survive.
    final keep = File('${paths.appSupportRoot}/keep-me.txt');
    await keep.writeAsString('mine');

    await installerFor(manifest).uninstallAll();

    expect(Directory(paths.toolchainRoot).existsSync(), isFalse);
    expect(keep.existsSync(), isTrue);
  });

  test('garbage collection clears staging and trash', () async {
    await Directory('${paths.stagingDir}/leftover').create(recursive: true);
    await Directory('${paths.trashDir}/leftover').create(recursive: true);

    await installerFor(manifestFor()).collectGarbage();

    expect(Directory(paths.stagingDir).existsSync(), isFalse);
    expect(Directory(paths.trashDir).existsSync(), isFalse);
  });

  test('refuses a tool with no artifact for this platform', () async {
    final manifest = ToolManifest.tryParse(jsonEncode({
      'schemaVersion': 1,
      'manifestId': 'test',
      'baseUrl': '${server.url.origin}/',
      'tools': [
        {
          'id': 'opencode',
          'version': '1.18.4',
          'hostAccepts': '*',
          'installDir': 'opencode/1.18.4',
          'platforms': const <String, dynamic>{},
          'entrypoints': {'opencode': 'opencode'},
        },
      ],
    }))!;

    await expectLater(
      installerFor(manifest).install(
        manifest[ToolId.opencode]!,
        onProgress: (_) {},
      ),
      throwsA(
        isA<ToolInstallException>().having(
          (e) => e.message,
          'message',
          contains('not available'),
        ),
      ),
    );
  });
}
