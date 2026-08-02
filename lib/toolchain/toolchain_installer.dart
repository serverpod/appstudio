import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'flutter_tools_cache.dart';
import 'install_progress.dart';
import 'tool_status.dart';
import 'toolchain_manifest.dart';
import 'toolchain_paths.dart';

class ToolInstallException implements Exception {
  const ToolInstallException(this.message, {this.detail});

  final String message;
  final String? detail;

  @override
  String toString() => message;
}

class CancelToken {
  var _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  void throwIfCancelled() {
    if (_cancelled) throw const _Cancelled();
  }
}

class _Cancelled implements Exception {
  const _Cancelled();
}

/// Downloads, verifies and installs tool artifacts.
///
/// Install is atomic in the only sense macOS offers: the new tree is built in
/// `.staging` and swapped in with two same-volume renames. A crash therefore
/// leaves the tool reading as `notFound`, never half-installed.
class ToolchainInstaller {
  ToolchainInstaller({
    required this.paths,
    required this.manifest,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final ToolchainPaths paths;
  final ToolManifest manifest;
  final http.Client _http;

  /// Headroom over the raw requirement, so we never fill the disk exactly.
  static const _diskHeadroom = 1.1;

  static const _maxRetries = 3;
  static const _idleTimeout = Duration(seconds: 60);

  /// Progress is throttled to this, or [_progressBytes], whichever is less
  /// frequent — a notify per chunk on a 673 MB download will melt the UI.
  static const _progressInterval = Duration(milliseconds: 100);
  static const _progressBytes = 1024 * 1024;

  void close() => _http.close();

  /// Installs [specs] sequentially, reporting after every step.
  ///
  /// Never throws for an individual tool: a failure is reported through
  /// [onProgress] so the remaining tools still install.
  Future<void> installAll(
    List<ToolSpec> specs, {
    required void Function(InstallProgress progress) onProgress,
    CancelToken? cancel,
  }) async {
    final token = cancel ?? CancelToken();
    final startedAt = DateTime.now();
    final state = <ToolId, ToolProgress>{
      for (final spec in specs)
        spec.id: ToolProgress(
          id: spec.id,
          phase: ToolPhase.queued,
          totalBytes: spec.artifactForCurrentPlatform?.downloadBytes ?? 0,
        ),
    };

    void report() => onProgress(
          InstallProgress(
            tools: state.values.toList(growable: false),
            startedAt: startedAt,
          ),
        );

    report();

    for (final spec in specs) {
      if (token.isCancelled) {
        state[spec.id] = state[spec.id]!.copyWith(phase: ToolPhase.cancelled);
        report();
        continue;
      }
      try {
        await install(
          spec,
          cancel: token,
          onProgress: (progress) {
            state[spec.id] = progress;
            report();
          },
        );
        state[spec.id] = state[spec.id]!.copyWith(phase: ToolPhase.done);
      } on _Cancelled {
        state[spec.id] = state[spec.id]!.copyWith(phase: ToolPhase.cancelled);
      } on ToolInstallException catch (e) {
        state[spec.id] =
            state[spec.id]!.copyWith(phase: ToolPhase.failed, error: e.message);
      } catch (e) {
        state[spec.id] =
            state[spec.id]!.copyWith(phase: ToolPhase.failed, error: '$e');
      }
      report();
    }
  }

  /// Installs one tool. Throws [ToolInstallException] on failure.
  Future<void> install(
    ToolSpec spec, {
    required void Function(ToolProgress progress) onProgress,
    CancelToken? cancel,
  }) async {
    final token = cancel ?? CancelToken();
    final artifact = spec.artifactForCurrentPlatform;
    if (artifact == null) {
      throw ToolInstallException(
        '${spec.displayName} is not available for this Mac.',
      );
    }

    var progress = ToolProgress(
      id: spec.id,
      phase: ToolPhase.preflight,
      totalBytes: artifact.downloadBytes,
    );
    onProgress(progress);

    await _ensureDirectories();
    await _preflightDisk(artifact);
    token.throwIfCancelled();

    final archive = File(
      p.join(paths.downloadsDir, '${spec.id.manifestId}-${spec.version}.tar.gz'),
    );

    progress = progress.copyWith(phase: ToolPhase.downloading);
    onProgress(progress);
    await _download(
      url: manifest.urlFor(artifact),
      target: archive,
      expectedBytes: artifact.downloadBytes,
      cancel: token,
      onBytes: (received, total) {
        progress = progress.copyWith(
          receivedBytes: received,
          totalBytes: total > 0 ? total : artifact.downloadBytes,
        );
        onProgress(progress);
      },
    );

    token.throwIfCancelled();
    progress = progress.copyWith(phase: ToolPhase.verifying);
    onProgress(progress);
    await _verify(archive, artifact.sha256);

    token.throwIfCancelled();
    progress = progress.copyWith(phase: ToolPhase.extracting);
    onProgress(progress);
    final staged = await _extract(archive, artifact, spec);

    try {
      token.throwIfCancelled();
      progress = progress.copyWith(phase: ToolPhase.finalizing);
      onProgress(progress);

      if (spec.id == ToolId.flutter) {
        // Required, or the first `flutter` run rebuilds flutter_tools and fails.
        await ensureFlutterToolsCache(staged.path);
      }
      await _validateEntrypoints(spec, staged);
      await _swapIntoPlace(spec, staged);
      await _recordInstalled(spec, artifact);
    } catch (_) {
      await _deleteQuietly(staged);
      rethrow;
    }

    await _deleteQuietly(archive);
    onProgress(progress.copyWith(phase: ToolPhase.done));
  }

  /// Removes a managed tool. Host and dev-repo copies are not ours to touch.
  Future<void> uninstall(ToolSpec spec) async {
    final dir = Directory(paths.installDirFor(spec));
    if (!await dir.exists()) return;
    final grave = Directory(
      p.join(paths.trashDir, '${spec.id.manifestId}-${_stamp()}'),
    );
    await grave.parent.create(recursive: true);
    await dir.rename(grave.path);
    unawaited(_deleteQuietly(grave));
    await _forgetInstalled(spec);
  }

  /// Removes everything managed, leaving host tools and `~/.pub-cache` alone.
  Future<void> uninstallAll() async {
    final root = Directory(paths.toolchainRoot);
    if (!await root.exists()) return;
    // Rename first so the UI is correct immediately; deleting 1.7 GB takes a
    // while and must not block.
    final grave = Directory(p.join(paths.appSupportRoot, '.trash-${_stamp()}'));
    await root.rename(grave.path);
    unawaited(_deleteQuietly(grave));
  }

  /// Clears crashed installs and stale part files. Cheap, runs at startup.
  Future<void> collectGarbage() async {
    for (final dir in [paths.stagingDir, paths.trashDir]) {
      await _deleteQuietly(Directory(dir));
    }
    final downloads = Directory(paths.downloadsDir);
    if (!await downloads.exists()) return;
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    await for (final entity in downloads.list()) {
      if (entity is! File || !entity.path.endsWith('.part')) continue;
      try {
        if ((await entity.stat()).modified.isBefore(cutoff)) {
          await entity.delete();
        }
      } catch (_) {}
    }
  }

  // -- steps ----------------------------------------------------------------

  Future<void> _ensureDirectories() async {
    for (final dir in [paths.downloadsDir, paths.stagingDir]) {
      await Directory(dir).create(recursive: true);
    }
  }

  Future<void> _preflightDisk(ToolArtifact artifact) async {
    final needed =
        ((artifact.downloadBytes + artifact.installedBytes) * _diskHeadroom)
            .round();
    final free = await _freeBytes(paths.toolchainRoot);
    if (free != null && free < needed) {
      throw ToolInstallException(
        'Not enough disk space: needs ${_mb(needed)}, '
        '${_mb(free)} free.',
      );
    }
  }

  Future<int?> _freeBytes(String path) async {
    try {
      final result = await Process.run('/bin/df', ['-k', path]);
      if (result.exitCode != 0) return null;
      final lines = (result.stdout as String).trim().split('\n');
      if (lines.length < 2) return null;
      // Filesystem 1024-blocks Used Available ...
      final columns = lines[1].split(RegExp(r'\s+'));
      if (columns.length < 4) return null;
      final availableKb = int.tryParse(columns[3]);
      return availableKb == null ? null : availableKb * 1024;
    } catch (_) {
      return null;
    }
  }

  Future<void> _download({
    required Uri url,
    required File target,
    required int expectedBytes,
    required CancelToken cancel,
    required void Function(int received, int total) onBytes,
  }) async {
    final part = File('${target.path}.part');
    Object? lastError;

    for (var attempt = 1; attempt <= _maxRetries; attempt++) {
      cancel.throwIfCancelled();
      try {
        await _downloadOnce(
          url: url,
          part: part,
          target: target,
          expectedBytes: expectedBytes,
          cancel: cancel,
          onBytes: onBytes,
        );
        return;
      } on _Cancelled {
        rethrow;
      } catch (e) {
        lastError = e;
        if (attempt == _maxRetries) break;
        await Future<void>.delayed(Duration(seconds: [1, 3, 9][attempt - 1]));
      }
    }
    throw ToolInstallException(
      'Download failed. Check your internet connection and try again.',
      detail: '$lastError',
    );
  }

  Future<void> _downloadOnce({
    required Uri url,
    required File part,
    required File target,
    required int expectedBytes,
    required CancelToken cancel,
    required void Function(int received, int total) onBytes,
  }) async {
    var resumeFrom = 0;
    if (await part.exists()) {
      resumeFrom = await part.length();
    }

    final request = http.Request('GET', url);
    if (resumeFrom > 0) {
      request.headers['Range'] = 'bytes=$resumeFrom-';
    }

    final response = await _http.send(request);

    if (response.statusCode == 416) {
      // The part file is at or past the end — start over rather than guess.
      await _deleteQuietly(part);
      throw const ToolInstallException('Stale partial download; retrying.');
    }
    if (response.statusCode == 200) {
      // Server ignored the range: whatever we had is not a prefix of this.
      resumeFrom = 0;
    } else if (response.statusCode != 206 && resumeFrom > 0) {
      throw ToolInstallException('Unexpected status ${response.statusCode}.');
    } else if (response.statusCode != 200 && response.statusCode != 206) {
      throw ToolInstallException('Unexpected status ${response.statusCode}.');
    }

    final total = response.contentLength == null
        ? expectedBytes
        : resumeFrom + response.contentLength!;

    final sink = part.openWrite(
      mode: resumeFrom > 0 ? FileMode.append : FileMode.write,
    );
    var received = resumeFrom;
    var lastReport = DateTime.now();
    var lastReportedBytes = received;

    try {
      await for (final chunk in response.stream.timeout(_idleTimeout)) {
        cancel.throwIfCancelled();
        sink.add(chunk);
        received += chunk.length;
        final now = DateTime.now();
        if (now.difference(lastReport) >= _progressInterval &&
            received - lastReportedBytes >= _progressBytes) {
          lastReport = now;
          lastReportedBytes = received;
          onBytes(received, total);
        }
      }
    } finally {
      await sink.close();
    }

    onBytes(received, total);
    await _deleteQuietly(target);
    await part.rename(target.path);
  }

  Future<void> _verify(File archive, String expectedSha256) async {
    // One streaming pass over the finished file. Hashing incrementally across a
    // resume would mean persisting partial hash state for no real gain.
    final digest = await sha256.bind(archive.openRead()).first;
    final actual = digest.toString();
    if (actual != expectedSha256.toLowerCase()) {
      await _deleteQuietly(archive);
      throw const ToolInstallException(
        'The download was corrupted. Try again — if it keeps failing, check '
        'for a proxy that modifies downloads.',
      );
    }
  }

  Future<Directory> _extract(
    File archive,
    ToolArtifact artifact,
    ToolSpec spec,
  ) async {
    final staged = Directory(
      p.join(paths.stagingDir, '${spec.id.manifestId}-${_stamp()}'),
    );
    await staged.create(recursive: true);

    // bsdtar preserves symlinks, mode bits and the exec bit, which bin/cache
    // and .git both need. Mach-O signatures live inside the file and survive.
    final result = await Process.run('/usr/bin/tar', [
      '-xzf',
      archive.path,
      '-C',
      staged.path,
      if (artifact.stripComponents > 0)
        '--strip-components=${artifact.stripComponents}',
    ]);
    if (result.exitCode != 0) {
      await _deleteQuietly(staged);
      throw ToolInstallException(
        'Could not unpack ${spec.displayName}.',
        detail: '${result.stderr}',
      );
    }

    // Belt and braces: files we write are not quarantined (the app does not opt
    // into LSFileQuarantineEnabled), but stripping costs nothing.
    await Process.run('/usr/bin/xattr', ['-dr', 'com.apple.quarantine', staged.path]);
    return staged;
  }

  Future<void> _validateEntrypoints(ToolSpec spec, Directory staged) async {
    for (final relative in spec.entrypoints.values) {
      final file = File(p.join(staged.path, relative));
      if (!await file.exists()) {
        throw ToolInstallException(
          '${spec.displayName} unpacked without $relative.',
        );
      }
    }
  }

  Future<void> _swapIntoPlace(ToolSpec spec, Directory staged) async {
    final destination = Directory(paths.installDirFor(spec));
    await destination.parent.create(recursive: true);

    Directory? grave;
    if (await destination.exists()) {
      grave = Directory(
        p.join(paths.trashDir, '${spec.id.manifestId}-${_stamp()}'),
      );
      await grave.parent.create(recursive: true);
      await destination.rename(grave.path);
    }

    try {
      await staged.rename(destination.path);
    } catch (e) {
      // Put the old tree back rather than leaving nothing installed.
      if (grave != null && await grave.exists()) {
        await grave.rename(destination.path);
      }
      throw ToolInstallException(
        'Could not move ${spec.displayName} into place.',
        detail: '$e',
      );
    }

    if (grave != null) unawaited(_deleteQuietly(grave));
  }

  Future<void> _recordInstalled(ToolSpec spec, ToolArtifact artifact) async {
    final installed = await _readInstalled();
    installed[spec.id.manifestId] = {
      'version': spec.version.toString(),
      'build': spec.build,
      'sha256': artifact.sha256,
      'sizeBytes': artifact.installedBytes,
      'installedAt': DateTime.now().toUtc().toIso8601String(),
    };
    await _writeInstalled(installed);
  }

  Future<void> _forgetInstalled(ToolSpec spec) async {
    final installed = await _readInstalled();
    if (installed.remove(spec.id.manifestId) == null) return;
    await _writeInstalled(installed);
  }

  Future<Map<String, dynamic>> _readInstalled() async {
    try {
      final file = File(paths.installedFile);
      if (!await file.exists()) return {};
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return {};
  }

  Future<void> _writeInstalled(Map<String, dynamic> installed) async {
    final file = File(paths.installedFile);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(installed),
    );
  }

  Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) {
        await entity.delete(recursive: true);
      }
    } catch (_) {}
  }

  static String _stamp() => DateTime.now().microsecondsSinceEpoch.toString();

  static String _mb(int bytes) => '${(bytes / (1000 * 1000)).round()} MB';
}
