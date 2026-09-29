import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'install_plan.dart';
import 'install_progress.dart';
import 'install_record.dart';
import 'login_shell_path.dart';
import 'shell_profile.dart';
import 'tool_probe.dart';
import 'tool_status.dart';
import 'tool_version.dart';
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
    if (_cancelled) throw const InstallCancelled();
  }
}

class InstallCancelled implements Exception {
  const InstallCancelled();
}

typedef ProgressSink = void Function(ToolProgress progress);

/// Installs the tools the way their own instructions do, into the places
/// those instructions name:
///
///  * the Command Line Tools through Apple's installer (`xcode-select
///    --install`),
///  * Flutter from its official archive into `~/develop/flutter`, with
///    Flutter's `PATH` line,
///  * the Serverpod CLI with `dart install`, with the `PATH` line it asks for.
///
/// Nothing here writes the install record; each step returns what it did and
/// the controller records it, so a step that fails records nothing.
class ToolchainInstaller {
  ToolchainInstaller({
    required this.paths,
    http.Client? httpClient,
    LoginShellPathReader? loginShellPath,
    ShellProfile? profile,
    this.pollInterval = const Duration(seconds: 3),
  })  : _http = httpClient ?? http.Client(),
        _loginShellPath = loginShellPath ?? captureLoginShellPath,
        profile = profile ?? ShellProfile.resolve(home: paths.home);

  final ToolchainPaths paths;
  final ShellProfile profile;
  final Duration pollInterval;
  final http.Client _http;
  final LoginShellPathReader _loginShellPath;

  /// Room over the archive size for the archive itself plus the unpacked SDK.
  static const _diskFactor = 3;

  static const _maxRetries = 3;
  static const _idleTimeout = Duration(seconds: 60);

  /// Progress is throttled to this, or [_progressBytes], whichever is less
  /// frequent — a notify per chunk on a 2 GB download will melt the UI.
  static const _progressInterval = Duration(milliseconds: 100);
  static const _progressBytes = 1024 * 1024;

  /// Apple's installer app. Watched so closing it early reads as a failure
  /// rather than an endless wait.
  static const _cltInstallerProcess = 'Install Command Line Developer Tools';

  void close() => _http.close();

  // -- Command Line Tools ---------------------------------------------------

  /// Opens Apple's installer and waits for the tools to appear.
  ///
  /// `xcode-select --install` returns at once and reports nothing, and there
  /// is no unattended alternative that does not need the user's password —
  /// so the user clicks through Apple's own dialog and this polls.
  Future<RecordedInstall> installCommandLineTools({
    required ProgressSink onProgress,
    required CancelToken cancel,
  }) async {
    onProgress(ToolProgress(
      id: ToolId.commandLineTools,
      phase: ToolPhase.waitingForApple,
      phaseStartedAt: DateTime.now(),
    ));

    // Exits non-zero when an install is already in place or already running;
    // either way the poll below is what decides.
    await Process.run('/usr/bin/xcode-select', const ['--install']);

    var sawInstaller = false;
    DateTime? installerGoneAt;
    while (true) {
      cancel.throwIfCancelled();
      if (await commandLineToolsInstalled()) {
        return RecordedInstall(
          id: ToolId.commandLineTools,
          installedAt: DateTime.now(),
        );
      }
      final running = await _processRunning(_cltInstallerProcess);
      if (running) {
        sawInstaller = true;
        installerGoneAt = null;
      } else if (sawInstaller) {
        // The tools land a moment after the window closes; give them that.
        installerGoneAt ??= DateTime.now();
        if (DateTime.now().difference(installerGoneAt) >
            const Duration(seconds: 15)) {
          throw const ToolInstallException(
            'The Command Line Tools installer closed before it finished.',
          );
        }
      }
      await Future<void>.delayed(pollInterval);
    }
  }

  /// A developer directory is selected and it has a real `git` in it.
  static Future<bool> commandLineToolsInstalled() async {
    try {
      final result = await Process.run('/usr/bin/xcode-select', const ['-p']);
      if (result.exitCode != 0) return false;
      final dir = (result.stdout as String).trim();
      return dir.isNotEmpty &&
          await File(p.join(dir, 'usr', 'bin', 'git')).exists();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _processRunning(String name) async {
    try {
      final result = await Process.run('/usr/bin/pgrep', ['-f', name]);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Removes the standalone Command Line Tools the way Apple documents it,
  /// behind the system's own administrator prompt. A full Xcode is never
  /// touched: only `/Library/Developer/CommandLineTools` is removed.
  Future<void> uninstallCommandLineTools() async {
    const dir = '/Library/Developer/CommandLineTools';
    if (!await Directory(dir).exists()) return;
    final result = await Process.run('/usr/bin/osascript', [
      '-e',
      'do shell script "/bin/rm -rf $dir" with administrator privileges',
    ]);
    if (result.exitCode == 0) return;
    final error = '${result.stderr}';
    // -128 is "User canceled" from the password prompt.
    throw ToolInstallException(
      error.contains('-128')
          ? 'Removing the Command Line Tools was cancelled at the password '
              'prompt.'
          : 'Could not remove the Command Line Tools.',
      detail: error,
    );
  }

  // -- Flutter --------------------------------------------------------------

  /// Downloads, verifies and unpacks [release] into `~/develop/flutter`.
  ///
  /// [owned] is the record entry for a Flutter App Studio installed there
  /// earlier, which is replaced. Anything else already at that path belongs to
  /// the user and stops the install instead.
  Future<RecordedInstall> installFlutter(
    FlutterRelease release, {
    required ProgressSink onProgress,
    required CancelToken cancel,
    RecordedInstall? owned,
  }) async {
    final target = Directory(paths.flutterInstallDir);
    final expected = release.downloadBytes ?? 0;
    var progress = ToolProgress(
      id: ToolId.flutter,
      phase: ToolPhase.downloading,
      totalBytes: expected,
      phaseStartedAt: DateTime.now(),
    );
    onProgress(progress);

    await _checkTarget(target, owned: owned);
    await Directory(paths.downloadsDir).create(recursive: true);
    await target.parent.create(recursive: true);
    await _checkDiskSpace(target.parent.path, expected);
    cancel.throwIfCancelled();

    final archive = File(
      p.join(paths.downloadsDir, 'flutter_${release.version}.zip'),
    );
    await _download(
      url: release.archiveUrl,
      target: archive,
      expectedBytes: expected,
      cancel: cancel,
      onBytes: (received, total) {
        progress = progress.copyWith(
          receivedBytes: received,
          totalBytes: total > 0 ? total : expected,
        );
        onProgress(progress);
      },
    );

    cancel.throwIfCancelled();
    onProgress(progress = progress.copyWith(
      phase: ToolPhase.verifying,
      phaseStartedAt: DateTime.now(),
    ));
    await _verify(archive, release.sha256);

    cancel.throwIfCancelled();
    onProgress(progress = progress.copyWith(
      phase: ToolPhase.extracting,
      phaseStartedAt: DateTime.now(),
    ));
    final staging = Directory(
      p.join(target.parent.path, '.flutter-install-${_stamp()}'),
    );
    try {
      await _unzip(archive, staging);
      final unpacked = Directory(p.join(staging.path, 'flutter'));
      if (!await File(p.join(unpacked.path, 'bin', 'flutter')).exists()) {
        throw const ToolInstallException(
          'The Flutter archive unpacked without bin/flutter.',
        );
      }
      cancel.throwIfCancelled();
      // Our own earlier copy goes only now, once its replacement is ready.
      if (owned != null && await target.exists()) {
        await target.delete(recursive: true);
      }
      await unpacked.rename(target.path);
    } finally {
      await _deleteQuietly(staging);
    }
    await _deleteQuietly(archive);

    return RecordedInstall(
      id: ToolId.flutter,
      path: target.path,
      version: '${release.version}',
      installedAt: DateTime.now(),
    );
  }

  Future<void> _checkTarget(Directory target, {RecordedInstall? owned}) async {
    if (!await target.exists()) return;
    if (owned != null && p.equals(owned.path ?? '', target.path)) return;
    if (await target.list().isEmpty) {
      await target.delete();
      return;
    }
    throw ToolInstallException(
      '${_pretty(target.path)} already exists and is not a Flutter SDK App '
      'Studio installed. Move it somewhere else and try again.',
    );
  }

  /// First run of a fresh SDK: put it on the user's `PATH`, then fetch the web
  /// components so the first preview build does not stall on them.
  ///
  /// Returns the `PATH` line written, if any. The precache is best effort —
  /// Flutter fetches the same components on the first web build anyway, so a
  /// failure here only moves the wait.
  Future<RecordedPathLine?> configureFlutter(
    String root, {
    required ProgressSink onProgress,
  }) async {
    onProgress(ToolProgress(
      id: ToolId.flutter,
      phase: ToolPhase.configuring,
      phaseStartedAt: DateTime.now(),
    ));
    final bin = p.join(root, 'bin');
    final line = await addToShellPath(
      bin,
      flutterPathLine(bin, home: paths.home),
    );
    final result = await _runFlutter(root, const ['precache', '--web']);
    if (result.exitCode != 0) {
      stderr.writeln('flutter precache --web failed: ${result.stderr}');
    }
    return line;
  }

  /// `flutter upgrade` on a copy App Studio installed.
  Future<RecordedInstall> upgradeFlutter(
    RecordedInstall owned, {
    required ProgressSink onProgress,
  }) async {
    final root = owned.path;
    if (root == null) {
      throw const ToolInstallException('No Flutter SDK to update.');
    }
    onProgress(ToolProgress(
      id: ToolId.flutter,
      phase: ToolPhase.upgrading,
      phaseStartedAt: DateTime.now(),
    ));
    final result = await _runFlutter(root, const ['upgrade']);
    if (result.exitCode != 0) {
      throw ToolInstallException(
        'flutter upgrade failed.',
        detail: _tail('${result.stdout}\n${result.stderr}'),
      );
    }
    final info = FlutterInfo.parse(await File(
      p.join(root, 'bin', 'cache', 'flutter.version.json'),
    ).readAsString());
    return owned.copyWith(version: info?.frameworkVersion?.toString());
  }

  Future<ProcessResult> _runFlutter(String root, List<String> args) {
    final env = Map<String, String>.from(Platform.environment)
      ..['PATH'] = '${p.join(root, 'bin')}:/usr/bin:/bin:/usr/sbin:/sbin'
      ..remove('FLUTTER_ROOT');
    return Process.run(
      p.join(root, 'bin', 'flutter'),
      args,
      environment: env,
      includeParentEnvironment: false,
    );
  }

  Future<void> uninstallFlutter(RecordedInstall owned) async {
    final root = owned.path;
    if (root != null) await _deleteQuietly(Directory(root));
    await removeShellLines(owned.pathLines);
  }

  // -- Serverpod CLI --------------------------------------------------------

  /// `dart install serverpod_cli@<version>`, then its `PATH` line.
  Future<RecordedInstall> installServerpod(
    ToolVersion version, {
    required String dartExecutable,
    required ProgressSink onProgress,
  }) async {
    onProgress(ToolProgress(
      id: ToolId.serverpodCli,
      phase: ToolPhase.installing,
      phaseStartedAt: DateTime.now(),
    ));
    final dartBin = p.dirname(dartExecutable);
    final env = Map<String, String>.from(Platform.environment)
      // `dart install` runs install_name_tool through the /usr/bin shims,
      // which the Command Line Tools make real.
      ..['PATH'] = '$dartBin:/usr/bin:/bin:/usr/sbin:/sbin';
    final result = await Process.run(
      dartExecutable,
      ['install', 'serverpod_cli@$version'],
      environment: env,
      includeParentEnvironment: false,
    );
    if (result.exitCode != 0) {
      throw ToolInstallException(
        'dart install serverpod_cli failed.',
        detail: _tail('${result.stdout}\n${result.stderr}'),
      );
    }

    final binDir = paths.dartInstallBinDir;
    final line = await addToShellPath(
      binDir,
      dartInstallPathLine(binDir, home: paths.home),
    );
    return RecordedInstall(
      id: ToolId.serverpodCli,
      path: p.join(binDir, 'serverpod'),
      version: '$version',
      installedAt: DateTime.now(),
      pathLines: [?line],
    );
  }

  /// `dart uninstall serverpod_cli`. Its `PATH` line stays while anything else
  /// is still installed with `dart install` — that directory is shared.
  Future<void> uninstallServerpod(
    RecordedInstall owned, {
    String? dartExecutable,
  }) async {
    if (dartExecutable != null) {
      final result = await Process.run(
        dartExecutable,
        const ['uninstall', 'serverpod_cli'],
      );
      if (result.exitCode != 0) {
        throw ToolInstallException(
          'dart uninstall serverpod_cli failed.',
          detail: _tail('${result.stdout}\n${result.stderr}'),
        );
      }
    } else if (owned.path case final path?) {
      // No Dart left to ask. The executable is what put it on the PATH.
      await _deleteQuietly(File(path));
    }

    final binDir = Directory(paths.dartInstallBinDir);
    final stillUsed = await binDir.exists() && !await binDir.list().isEmpty;
    if (!stillUsed) await removeShellLines(owned.pathLines);
  }

  // -- PATH -----------------------------------------------------------------

  /// Adds [line] to the shell profile unless [dir] is already on the `PATH`
  /// the user's own shell sets up. Returns the line when it was written — the
  /// only case in which it is App Studio's to remove later.
  Future<RecordedPathLine?> addToShellPath(String dir, String line) async {
    final rc = profile.path;
    if (rc == null) return null;
    String? shellPath;
    try {
      shellPath = await _loginShellPath();
    } catch (_) {}
    if (pathContainsDir(shellPath, dir)) return null;
    final written = await appendShellLine(rc, line);
    return written ? RecordedPathLine(file: rc, line: line) : null;
  }

  Future<void> removeShellLines(List<RecordedPathLine> lines) async {
    for (final line in lines) {
      await removeShellLine(line.file, line.line);
    }
  }

  // -- Legacy ---------------------------------------------------------------

  /// Removes what builds before this one installed: their private toolchain
  /// and wrapper scripts in Application Support, and the fenced `PATH` block
  /// that pointed the user's shell at those scripts.
  Future<void> removeLegacyInstall() async {
    for (final rc in paths.legacyShellFiles) {
      await removeLegacyShellBlock(rc);
    }
    for (final path in paths.legacyPaths) {
      final dir = Directory(path);
      if (await dir.exists()) await dir.delete(recursive: true);
    }
  }

  /// Clears what a crashed install left behind. Cheap, runs at startup.
  Future<void> collectGarbage() async {
    final develop = Directory(p.dirname(paths.flutterInstallDir));
    if (await develop.exists()) {
      await for (final entity in develop.list()) {
        if (entity is Directory &&
            p.basename(entity.path).startsWith('.flutter-install-')) {
          await _deleteQuietly(entity);
        }
      }
    }
    final downloads = Directory(paths.downloadsDir);
    if (!await downloads.exists()) return;
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    await for (final entity in downloads.list()) {
      if (entity is! File) continue;
      try {
        if ((await entity.stat()).modified.isBefore(cutoff)) {
          await entity.delete();
        }
      } catch (_) {}
    }
  }

  // -- download -------------------------------------------------------------

  Future<void> _checkDiskSpace(String path, int archiveBytes) async {
    if (archiveBytes <= 0) return;
    final needed = archiveBytes * _diskFactor;
    final free = await _freeBytes(path);
    if (free != null && free < needed) {
      throw ToolInstallException(
        'Not enough disk space: needs ${_mb(needed)}, ${_mb(free)} free.',
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
      } on InstallCancelled {
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
    } else if (response.statusCode != 206) {
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
    if (digest.toString() != expectedSha256.toLowerCase()) {
      await _deleteQuietly(archive);
      throw const ToolInstallException(
        'The download was corrupted. Try again — if it keeps failing, check '
        'for a proxy that modifies downloads.',
      );
    }
  }

  /// `unzip`, as Flutter's own instructions use — it keeps the symlinks and
  /// exec bits the SDK needs. It is a real binary in `/usr/bin`, not one of
  /// the Command Line Tools shims.
  Future<void> _unzip(File archive, Directory into) async {
    await into.create(recursive: true);
    final result = await Process.run(
      '/usr/bin/unzip',
      ['-q', '-o', archive.path, '-d', into.path],
    );
    if (result.exitCode != 0) {
      throw ToolInstallException(
        'Could not unpack the Flutter SDK.',
        detail: _tail('${result.stderr}'),
      );
    }
  }

  // -- helpers --------------------------------------------------------------

  String _pretty(String path) => p.isWithin(paths.home, path)
      ? '~/${p.relative(path, from: paths.home)}'
      : path;

  Future<void> _deleteQuietly(FileSystemEntity entity) async {
    try {
      if (await entity.exists()) {
        await entity.delete(recursive: true);
      }
    } catch (_) {}
  }

  static String _tail(String output) {
    final lines = const LineSplitter()
        .convert(output.trim())
        .where((l) => l.trim().isNotEmpty)
        .toList();
    return lines.skip(lines.length > 20 ? lines.length - 20 : 0).join('\n');
  }

  static String _stamp() => DateTime.now().microsecondsSinceEpoch.toString();

  static String _mb(int bytes) => '${(bytes / (1000 * 1000)).round()} MB';
}
