import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../platform/host.dart';
import '../platform/windows/win32_system.dart';
import '../platform/windows/windows_system.dart';
import '../process/tool_command.dart';
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
    WindowsSystem? windows,
    this.pollInterval = const Duration(seconds: 3),
    @visibleForTesting
    Future<ProcessResult> Function(String executable, List<String> arguments)?
        runProcess,
  })  : _http = httpClient ?? http.Client(),
        _runProcess = runProcess ?? Process.run,
        _loginShellPath = loginShellPath ?? captureLoginShellPath,
        profile = profile ??
            ShellProfile.resolve(home: paths.home, host: paths.host),
        windows = windows ??
            (paths.host.isWindows ? Win32System() : const NoWindowsSystem());

  final ToolchainPaths paths;
  final ShellProfile profile;
  final Duration pollInterval;
  final http.Client _http;
  final LoginShellPathReader _loginShellPath;
  final Future<ProcessResult> Function(String executable, List<String> args)
      _runProcess;

  /// The registry and the UAC prompt, on Windows.
  final WindowsSystem windows;

  HostPlatform get _host => paths.host;

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

  /// Its bundle id, for bringing its window forward.
  static const _cltInstallerBundleId =
      'com.apple.dt.CommandLineTools.installondemand';

  void close() => _http.close();

  // -- Developer Mode (Windows) ---------------------------------------------

  /// Turns Developer Mode on. It is a machine-wide setting, so Windows asks
  /// for an administrator's approval in its own UAC prompt; App Studio itself
  /// never runs elevated. What happens is read back from the registry rather
  /// than taken from the prompt's outcome.
  Future<RecordedInstall> enableDeveloperMode({
    required ProgressSink onProgress,
  }) async {
    onProgress(ToolProgress(
      id: ToolId.developerMode,
      phase: ToolPhase.waitingForApproval,
      phaseStartedAt: DateTime.now(),
    ));
    if (developerModeLockedByPolicy(windows)) {
      throw const ToolInstallException(
        'Developer Mode is turned off by your organization\'s policy. Ask '
        'whoever manages this PC to allow it, then choose Try again.',
      );
    }
    final declined = !await _setDeveloperMode(on: true);
    if (developerModeEnabled(windows)) {
      return RecordedInstall(
        id: ToolId.developerMode,
        installedAt: DateTime.now(),
      );
    }
    throw ToolInstallException(
      '${declined ? 'Windows did not get approval to turn on Developer Mode.' : 'Developer Mode is still off.'} '
      'Turn it on yourself in Settings → System → For developers, then '
      'choose Try again.',
    );
  }

  /// Turns Developer Mode back off, through the same UAC prompt. Only offered
  /// when App Studio turned it on.
  Future<void> disableDeveloperMode() async {
    if (!developerModeEnabled(windows)) return;
    final declined = !await _setDeveloperMode(on: false);
    if (!developerModeEnabled(windows)) return;
    throw ToolInstallException(
      declined
          ? 'Windows did not get approval to turn off Developer Mode.'
          : 'Developer Mode is still on. Turn it off in Settings → System → '
              'For developers.',
    );
  }

  /// One elevated `reg add`. False when the prompt was declined or the
  /// program could not start; the registry says whether it worked.
  Future<bool> _setDeveloperMode({required bool on}) async {
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    return await windows.runElevated(
          _host.path.join(systemRoot, 'System32', 'reg.exe'),
          'add "HKLM\\$kAppModelUnlockKey" /v $kDeveloperModeValue '
          '/t REG_DWORD /d ${on ? 1 : 0} /f',
        ) !=
        null;
  }

  // -- Git for Windows ------------------------------------------------------

  /// Git for Windows' own installer, downloaded from its GitHub release and
  /// checked against the digest GitHub publishes, run silently for this user
  /// only — no administrator, nothing outside the user's profile. It adds its
  /// `cmd` directory to the user's `Path` itself, so the line is its to
  /// remove, not App Studio's.
  Future<RecordedInstall> installGit(
    GitRelease release, {
    required ProgressSink onProgress,
    required CancelToken cancel,
  }) async {
    final expected = release.downloadBytes ?? 0;
    var progress = ToolProgress(
      id: ToolId.git,
      phase: ToolPhase.downloading,
      totalBytes: expected,
      phaseStartedAt: DateTime.now(),
    );
    onProgress(progress);
    await Directory(paths.downloadsDir).create(recursive: true);
    final installer = File(
      _host.path.join(paths.downloadsDir, 'Git-${release.version}.exe'),
    );
    await _download(
      url: release.installerUrl,
      target: installer,
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
    await _verify(installer, release.sha256);

    cancel.throwIfCancelled();
    onProgress(progress = progress.copyWith(
      phase: ToolPhase.installing,
      phaseStartedAt: DateTime.now(),
    ));
    final ProcessResult result;
    try {
      result = await Process.run(installer.path, const [
        '/VERYSILENT',
        '/NORESTART',
        '/NOCANCEL',
        '/SP-',
        '/SUPPRESSMSGBOXES',
        '/CURRENTUSER',
        '/NOICONS',
        '/o:PathOption=Cmd',
      ]);
    } finally {
      await _deleteQuietly(installer);
    }
    final root = _host.path.join(
      Platform.environment['LOCALAPPDATA'] ??
          _host.path.join(paths.home, 'AppData', 'Local'),
      'Programs',
      'Git',
    );
    final git = File(_host.path.join(root, 'cmd', 'git.exe'));
    if (result.exitCode != 0 || !await git.exists()) {
      throw ToolInstallException(
        'Git for Windows could not be installed (exit ${result.exitCode}).',
        detail: _tail('${result.stdout}\n${result.stderr}'),
      );
    }
    await _enableGitLongPaths(git.path);
    return RecordedInstall(
      id: ToolId.git,
      path: root,
      version: '${release.version}',
      installedAt: DateTime.now(),
    );
  }

  /// `core.longpaths true`, so Git can check out the deep trees Flutter and
  /// pub produce, but only when the user has not set it either way. Best
  /// effort: Git works without it for almost every project.
  Future<void> _enableGitLongPaths(String git) async {
    try {
      final current = await _runProcess(
        git,
        const ['config', '--global', '--get', 'core.longpaths'],
      );
      // Exit 1 is "not set"; anything set, true or false, is the user's.
      if (current.exitCode != 1) return;
      await _runProcess(
        git,
        const ['config', '--global', 'core.longpaths', 'true'],
      );
    } catch (_) {}
  }

  /// How long Git's uninstaller gets to finish.
  static const gitUninstallTimeout = Duration(minutes: 3);

  /// Git for Windows' own uninstaller, silently. It takes the `Path` entry
  /// its installer added with it.
  ///
  /// Inno Setup's uninstaller copies itself to the temp folder and returns
  /// while that copy does the work, so its exit says nothing: `git.exe`
  /// going is what counts.
  Future<void> uninstallGit(RecordedInstall owned) async {
    final root = owned.path;
    if (root == null) return;
    final git = File(_host.path.join(root, 'cmd', 'git.exe'));
    final uninstaller = File(_host.path.join(root, 'unins000.exe'));
    if (!await uninstaller.exists()) {
      if (!await git.exists()) return;
      throw const ToolInstallException(
        'Git for Windows has no uninstaller where App Studio installed it. '
        'Remove it from Settings → Apps → Installed apps.',
      );
    }
    final result = await _runProcess(uninstaller.path, const [
      '/VERYSILENT',
      '/NORESTART',
      '/SUPPRESSMSGBOXES',
    ]);
    if (result.exitCode != 0) {
      throw ToolInstallException(
        'Git for Windows could not be uninstalled (exit ${result.exitCode}).',
        detail: _tail('${result.stdout}\n${result.stderr}'),
      );
    }
    final deadline = DateTime.now().add(gitUninstallTimeout);
    while (await git.exists()) {
      if (DateTime.now().isAfter(deadline)) {
        throw const ToolInstallException(
          'Git for Windows is still installed. Close any program using git '
          'and remove it from Settings → Apps → Installed apps.',
        );
      }
      await Future<void>.delayed(pollInterval);
    }
    // Whatever the uninstaller left in the folder App Studio chose.
    await _deleteQuietly(Directory(root));
  }

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
    var raised = 0;
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
        // Apple's installer opens *behind* App Studio, where it is easy to
        // miss while the dialog here says to follow it. Twice, a poll apart:
        // its window can appear a moment after its process does.
        if (raised < 2) {
          raised++;
          await _bringToFront(_cltInstallerBundleId);
        }
      } else if (sawInstaller) {
        // The tools land a moment after the window closes; give them that.
        installerGoneAt ??= DateTime.now();
        if (DateTime.now().difference(installerGoneAt) >
            const Duration(seconds: 15)) {
          throw const ToolInstallException(
            'Apple\'s installer was closed before it finished.',
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

  /// Activates a running app through LaunchServices. `open` on an app that
  /// is already running brings it forward rather than starting a second copy,
  /// and unlike an AppleScript `activate` it needs no automation permission.
  Future<void> _bringToFront(String bundleId) async {
    try {
      await Process.run('/usr/bin/open', ['-b', bundleId]);
    } catch (_) {
      // Cosmetic: the install works either way.
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
          ? 'Removing Apple\'s command line tools was cancelled.'
          : 'Could not remove Apple\'s command line tools.',
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
      if (!await File(
        p.join(unpacked.path, 'bin', _host.flutterLauncherName),
      ).exists()) {
        throw const ToolInstallException(
          'The Flutter download is incomplete. Try again.',
        );
      }
      cancel.throwIfCancelled();
      // Our own earlier copy goes only now, once its replacement is ready.
      if (owned != null && await target.exists()) {
        await target.delete(recursive: true);
      }
      await _renameWithRetry(unpacked, target.path);
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
      '${_pretty(target.path)} already exists, and App Studio did not put it '
      'there. Move it somewhere else and try again.',
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
      throw const ToolInstallException('There is no Flutter to update.');
    }
    onProgress(ToolProgress(
      id: ToolId.flutter,
      phase: ToolPhase.upgrading,
      phaseStartedAt: DateTime.now(),
    ));
    final result = await _runFlutter(root, const ['upgrade']);
    if (result.exitCode != 0) {
      throw ToolInstallException(
        'Flutter could not be updated.',
        detail: _tail('${result.stdout}\n${result.stderr}'),
      );
    }
    final info = FlutterInfo.parse(await File(
      p.join(root, 'bin', 'cache', 'flutter.version.json'),
    ).readAsString());
    return owned.copyWith(version: info?.frameworkVersion?.toString());
  }

  Future<ProcessResult> _runFlutter(String root, List<String> args) {
    if (_host.isWindows) {
      // `flutter.bat` needs git, and the Git for Windows installed a step
      // earlier is only on the registry's `Path`, not on ours.
      final env = _host.copyEnvironment(Platform.environment)
        ..['PATH'] = [
          _host.path.join(root, 'bin'),
          ...?registryPath(windows)?.split(';'),
          ...?Platform.environment['PATH']?.split(';'),
        ].where((e) => e.isNotEmpty).join(';')
        ..remove('FLUTTER_ROOT');
      final command = resolveToolCommand(
        _host.path.join(root, 'bin', _host.flutterLauncherName),
        args,
        host: _host,
      );
      return Process.run(
        command.executable,
        command.arguments,
        environment: env,
        includeParentEnvironment: false,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    }
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
    final env = _host.isWindows
        ? (_host.copyEnvironment(Platform.environment)
          ..['PATH'] = [
            dartBin,
            ...?registryPath(windows)?.split(';'),
            ...?Platform.environment['PATH']?.split(';'),
          ].where((e) => e.isNotEmpty).join(';'))
        : (Map<String, String>.from(Platform.environment)
          // `dart install` runs install_name_tool through the /usr/bin shims,
          // which the Command Line Tools make real.
          ..['PATH'] = '$dartBin:/usr/bin:/bin:/usr/sbin:/sbin');
    final result = await Process.run(
      dartExecutable,
      ['install', 'serverpod_cli@$version'],
      environment: env,
      includeParentEnvironment: false,
    );
    if (result.exitCode != 0) {
      throw ToolInstallException(
        'Serverpod could not be installed.',
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
      path: p.join(binDir, _host.installedExecutableName('serverpod')),
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
          'Serverpod could not be uninstalled.',
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
    if (_host.isWindows) return _addToUserPath(dir);
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
      if (line.file == kWindowsUserPathRecord) {
        _removeFromUserPath(line.line);
      } else {
        await removeShellLine(line.file, line.line);
      }
    }
  }

  /// Windows: [dir] at the end of the user's `Path` in the registry, unless
  /// it is already on the machine's or the user's. The stored value is edited
  /// as stored, so `%USERPROFILE%`-style entries survive, and written back as
  /// `REG_EXPAND_SZ` — the type Windows gives the user `Path` itself.
  RecordedPathLine? _addToUserPath(String dir) {
    if (pathContainsDir(registryPath(windows), dir, host: _host)) return null;
    final current = windows.readRawString(
            RegistryRoot.currentUser, kUserEnvironmentKey, 'Path') ??
        '';
    final updated = current.isEmpty
        ? dir
        : current.endsWith(';')
            ? '$current$dir'
            : '$current;$dir';
    if (!windows.writeUserExpandString(kUserEnvironmentKey, 'Path', updated)) {
      return null;
    }
    windows.broadcastEnvironmentChange();
    return RecordedPathLine(file: kWindowsUserPathRecord, line: dir);
  }

  /// Takes exactly the entry App Studio added out of the user's `Path`, and
  /// nothing else.
  void _removeFromUserPath(String dir) {
    final current = windows.readRawString(
        RegistryRoot.currentUser, kUserEnvironmentKey, 'Path');
    if (current == null) return;
    final entries = current.split(';');
    final kept = [
      for (final e in entries)
        if (!(e.isNotEmpty && _host.pathEquals(e, dir))) e,
    ];
    if (kept.length == entries.length) return;
    windows.writeUserExpandString(kUserEnvironmentKey, 'Path', kept.join(';'));
    windows.broadcastEnvironmentChange();
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
    // Windows: the tar.exe Windows ships (bsdtar) reads zip archives.
    final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final result = _host.isWindows
        ? await Process.run(
            _host.path.join(systemRoot, 'System32', 'tar.exe'),
            ['-xf', archive.path, '-C', into.path],
          )
        : await Process.run(
            '/usr/bin/unzip',
            ['-q', '-o', archive.path, '-d', into.path],
          );
    if (result.exitCode != 0) {
      throw ToolInstallException(
        'Could not unpack Flutter.',
        detail: _tail('${result.stderr}'),
      );
    }
  }

  // -- helpers --------------------------------------------------------------

  /// A rename that, on Windows, survives the moment Defender or the search
  /// indexer still holds one of the files just unpacked.
  Future<void> _renameWithRetry(Directory from, String to) async {
    for (var attempt = 1;; attempt++) {
      try {
        await from.rename(to);
        return;
      } on FileSystemException {
        if (!_host.isWindows || attempt >= 5) rethrow;
        await Future<void>.delayed(Duration(seconds: attempt));
      }
    }
  }

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
