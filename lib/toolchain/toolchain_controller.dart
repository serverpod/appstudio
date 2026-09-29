import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'install_plan.dart';
import 'install_progress.dart';
import 'install_record.dart';
import 'platform_key.dart';
import 'shell_profile.dart';
import 'tool_probe.dart';
import 'tool_status.dart';
import 'toolchain.dart';
import 'toolchain_installer.dart';
import 'toolchain_manifest.dart';
import 'toolchain_paths.dart';
import '../util/pretty_path.dart';
import '../ui/toolchain/tools_view.dart';

/// Owns the resolved [Toolchain] and re-resolves it on demand.
///
/// Consumers hold the controller, not a `Toolchain`, and read [current] at call
/// time. Capturing the value would strand them on a snapshot taken before the
/// user installed anything.
class ToolchainController extends ChangeNotifier implements ToolsView {
  ToolchainController({
    required Toolchain initial,
    required this.manifest,
    required this.paths,
    InstallRecord record = InstallRecord.empty,
    ToolchainInstaller? installer,
    this.probeSandbox,
  })  : _current = initial,
        // Both fields are mutable and private; initializing formals would leak
        // the underscores into the named-argument list. The ignore only covers
        // the line after it, so each assignment needs its own.
        // ignore: prefer_initializing_formals
        _record = record,
        // ignore: prefer_initializing_formals
        _installer = installer;

  /// Resolves everything needed to start. Probe failures do not throw: "no
  /// tools" is a state the UI can explain, a failed launch is not.
  static Future<ToolchainController> create() async {
    final paths = ToolchainPaths.resolve();
    final manifest = await ToolManifest.loadBaked(rootBundle.loadString);
    final record = await InstallRecord.load(paths.installRecordFile);

    Toolchain toolchain;
    try {
      toolchain = await Toolchain.resolve(
        manifest: manifest,
        paths: paths,
        record: record,
      );
    } catch (e) {
      debugPrint('ToolchainController: probe failed: $e');
      toolchain = Toolchain(
        ToolchainInventory(manifest: manifest, tools: const {}),
      );
    }

    return ToolchainController(
      initial: toolchain,
      manifest: manifest,
      paths: paths,
      record: record,
    );
  }

  final ToolManifest manifest;
  final ToolchainPaths paths;

  /// Replaces the machine for every re-probe. Tests only — see [ProbeSandbox].
  final ProbeSandbox? probeSandbox;

  Toolchain _current;
  InstallRecord _record;
  InstallPlan _plan = InstallPlan.empty;
  bool _refreshing = false;
  bool _planning = false;
  bool _disposed = false;

  ToolchainInstaller? _installer;
  InstallProgress? _progress;
  CancelToken? _cancel;
  String? _installError;
  bool _finalizing = false;

  ToolchainInstaller get installer =>
      _installer ??= ToolchainInstaller(paths: paths);

  Toolchain get current => _current;
  @override
  ToolchainInventory get inventory => _current.inventory;

  /// What App Studio has installed, per `~/.serverpod`.
  InstallRecord get record => _record;

  @override
  InstallPlan get plan => _plan;

  bool get isRefreshing => _refreshing;

  /// Non-null while an install is running, and until the next one starts.
  @override
  InstallProgress? get progress => _progress;

  /// True from the moment [installMissing] is called until every step it owns
  /// has finished — including the deep re-probe after the last tool lands.
  /// Dropping it the instant the steps were terminal put the setup dialog back
  /// on its plan for the second the re-probe took, which read as the install
  /// having been thrown away.
  @override
  bool get isInstalling =>
      _finalizing || (_progress != null && !_progress!.isDone);
  @override
  String? get installError => _installError;

  @override
  bool get isBusy => isInstalling || _refreshing || _planning;

  // -- plan -----------------------------------------------------------------

  @override
  Future<String?> preflight() async {
    if (_planning || isInstalling) return null;
    _planning = true;
    notifyListeners();
    final client = http.Client();
    try {
      final tools = <ToolId, PlannedTool>{};
      for (final status in inventory.installable) {
        tools[status.id] = await _planFor(client, status);
      }
      _plan = InstallPlan(Map.unmodifiable(tools));
      return null;
    } on PlanException catch (e) {
      return e.message;
    } catch (e) {
      debugPrint('ToolchainController: preflight failed: $e');
      return 'Could not prepare the install: $e';
    } finally {
      client.close();
      _planning = false;
      _notify();
    }
  }

  Future<PlannedTool> _planFor(http.Client client, ToolStatus status) async {
    switch (status.id) {
      case ToolId.commandLineTools:
        return const PlannedTool(id: ToolId.commandLineTools);
      case ToolId.flutter:
        final release = await fetchFlutterRelease(
          client,
          accepts: status.spec.accepts,
          arch: currentPlatformKey() == 'macos-arm64' ? 'arm64' : 'x64',
        );
        // An update runs `flutter upgrade`, which picks its own release; the
        // feed only says what that will be.
        return status.action == ToolAction.update
            ? PlannedTool(id: ToolId.flutter, version: release.version)
            : PlannedTool(
                id: ToolId.flutter,
                version: release.version,
                flutterRelease: release,
              );
      case ToolId.serverpodCli:
        return PlannedTool(
          id: ToolId.serverpodCli,
          version: await fetchServerpodVersion(
            client,
            accepts: status.spec.accepts,
          ),
        );
    }
  }

  // -- install --------------------------------------------------------------

  /// Clears crashed installs left behind by a previous run. Cheap; fire and
  /// forget at startup.
  Future<void> collectGarbage() async {
    try {
      await installer.collectGarbage();
    } catch (e) {
      debugPrint('ToolchainController: garbage collection failed: $e');
    }
  }

  @override
  Future<void> installMissing() async {
    if (isInstalling) return;
    final ids = [for (final t in inventory.installable) t.id];
    if (ids.isEmpty) return;

    if (!_plan.covers(ids)) {
      final error = await preflight();
      if (error != null) {
        _installError = error;
        _notify();
        return;
      }
    }

    _installError = null;
    _finalizing = true;
    final cancel = _cancel = CancelToken();
    final startedAt = DateTime.now();
    final state = <ToolId, ToolProgress>{
      for (final id in ids) id: ToolProgress(id: id, phase: ToolPhase.queued),
    };
    void report() {
      _progress = InstallProgress(
        tools: state.values.toList(growable: false),
        startedAt: startedAt,
      );
      _notify();
    }

    report();
    try {
      String? failure;
      for (final id in ids) {
        if (failure != null || cancel.isCancelled) {
          state[id] = state[id]!.copyWith(phase: ToolPhase.cancelled);
          report();
          continue;
        }
        try {
          await _installOne(id, cancel, (progress) {
            state[id] = progress;
            report();
          });
          state[id] = state[id]!.copyWith(phase: ToolPhase.done);
        } on InstallCancelled {
          state[id] = state[id]!.copyWith(phase: ToolPhase.cancelled);
        } catch (e) {
          // Each step needs the one before it — Flutter's `git`, the
          // Serverpod CLI's `dart` — so the first failure ends the run.
          failure = e is ToolInstallException ? e.message : '$e';
          if (e is ToolInstallException && e.detail != null) {
            debugPrint('ToolchainController: ${e.message}\n${e.detail}');
          }
          state[id] =
              state[id]!.copyWith(phase: ToolPhase.failed, error: failure);
        }
        report();
        // The next step reads what this one installed.
        await refresh();
      }
      _installError = failure;
      _cancel = null;
      await refresh(deep: true);
    } finally {
      // A throw here would otherwise leave the UI reporting an install that is
      // no longer running, with no way back to the plan.
      _finalizing = false;
      _notify();
    }
  }

  Future<void> _installOne(
    ToolId id,
    CancelToken cancel,
    ProgressSink onProgress,
  ) async {
    switch (id) {
      case ToolId.commandLineTools:
        await _remember(await installer.installCommandLineTools(
          onProgress: onProgress,
          cancel: cancel,
        ));

      case ToolId.flutter:
        final owned = _record[ToolId.flutter];
        if (inventory[id]?.action == ToolAction.update && owned != null) {
          await _remember(
            await installer.upgradeFlutter(owned, onProgress: onProgress),
          );
          return;
        }
        final release = _plan[id]?.flutterRelease;
        if (release == null) {
          throw const ToolInstallException('No Flutter release was chosen.');
        }
        final installed = await installer.installFlutter(
          release,
          onProgress: onProgress,
          cancel: cancel,
          owned: owned,
        );
        // Recorded before the first run, so an install interrupted during the
        // precache is still one App Studio knows it owns.
        final kept = owned?.pathLines ?? const <RecordedPathLine>[];
        final entry = RecordedInstall(
          id: installed.id,
          path: installed.path,
          version: installed.version,
          installedAt: installed.installedAt,
          pathLines: kept,
        );
        await _remember(entry);
        final line = await installer.configureFlutter(
          entry.path!,
          onProgress: onProgress,
        );
        if (line != null && !kept.contains(line)) {
          await _remember(entry.copyWith(pathLines: [...kept, line]));
        }

      case ToolId.serverpodCli:
        final dart = _current.dartExecutable;
        if (dart == null) {
          throw const ToolInstallException(
            'The Serverpod CLI is installed with Flutter\'s Dart, and no '
            'usable Flutter SDK was found.',
          );
        }
        final version = _plan[id]?.version;
        if (version == null) {
          throw const ToolInstallException(
            'No Serverpod CLI version was chosen.',
          );
        }
        final executable = p.join(paths.dartInstallBinDir, 'serverpod');
        final existedBefore = await File(executable).exists();
        final previous = _record[ToolId.serverpodCli];
        final installed = await installer.installServerpod(
          version,
          dartExecutable: dart,
          onProgress: onProgress,
        );
        // A copy the user had put there with `dart install` themselves stays
        // theirs; updating it does not make it ours to offer for removal.
        if (previous == null &&
            existedBefore &&
            installed.pathLines.isEmpty) {
          return;
        }
        await _remember(installed.copyWith(pathLines: {
          ...?previous?.pathLines,
          ...installed.pathLines,
        }.toList()));
    }
  }

  Future<void> _remember(RecordedInstall install) => _saveRecord(
        _record.withTool(install),
      );

  Future<void> _saveRecord(InstallRecord record) async {
    _record = record;
    try {
      await record.save(paths.installRecordFile);
    } catch (e) {
      // The tool is installed either way; losing the record only costs the
      // uninstall prefill.
      debugPrint('ToolchainController: could not save the install record: $e');
    }
  }

  /// Writes the in-memory record back to disk — after an uninstall deleted
  /// `~/.serverpod` out from under it.
  Future<void> persistRecord() => _saveRecord(_record);

  @override
  void cancelInstall() {
    _cancel?.cancel();
    notifyListeners();
  }

  // -- legacy ---------------------------------------------------------------

  @override
  Future<String?> removeLegacyInstall() async {
    try {
      await installer.removeLegacyInstall();
      return null;
    } catch (e) {
      debugPrint('ToolchainController: legacy cleanup failed: $e');
      return 'Could not remove the tools an earlier version installed: $e';
    } finally {
      await refresh();
    }
  }

  // -- uninstall ------------------------------------------------------------

  /// Tools App Studio installed that are still on this Mac — what uninstall
  /// offers, in the order it removes them.
  Future<List<ToolId>> removableTools() async {
    final found = <ToolId>[];
    for (final id in const [
      ToolId.serverpodCli,
      ToolId.flutter,
      ToolId.commandLineTools,
    ]) {
      final entry = _record[id];
      if (entry == null) continue;
      final present = switch (id) {
        // Only the standalone tools — a full Xcode is never ours.
        ToolId.commandLineTools =>
          await Directory('/Library/Developer/CommandLineTools').exists(),
        ToolId.flutter =>
          entry.path != null && await Directory(entry.path!).exists(),
        ToolId.serverpodCli =>
          entry.path != null && await File(entry.path!).exists(),
      };
      if (present) found.add(id);
    }
    return found;
  }

  /// Removes one tool App Studio installed, and forgets it. Throws on failure,
  /// so the uninstall can name what did not go.
  Future<void> uninstallTool(ToolId id) async {
    final entry = _record[id];
    if (entry == null) return;
    switch (id) {
      case ToolId.serverpodCli:
        await installer.uninstallServerpod(
          entry,
          dartExecutable: _current.dartExecutable,
        );
      case ToolId.flutter:
        await installer.uninstallFlutter(entry);
      case ToolId.commandLineTools:
        await installer.uninstallCommandLineTools();
    }
    await _saveRecord(_record.without(id));
  }

  /// Runs `dart pub cache clean`, the sanctioned way to empty `~/.pub-cache`.
  ///
  /// Separate from removing tools on purpose: that cache belongs to every
  /// Dart project on the machine. Returns an error message, or null.
  Future<String?> clearPubCache() async {
    final dart = _current.dartExecutable;
    if (dart == null) {
      return 'Dart is not available, so the cache cannot be cleared.';
    }
    try {
      final result = await Process.run(
        dart,
        const ['pub', 'cache', 'clean', '--force'],
        environment: _current.processEnvironment(),
      );
      if (result.exitCode == 0) return null;
      return '${result.stderr}'.trim().isEmpty
          ? 'dart pub cache clean failed (exit ${result.exitCode}).'
          : '${result.stderr}'.trim();
    } catch (e) {
      return '$e';
    }
  }

  // -- ToolsView ------------------------------------------------------------

  ShellProfile get _profile => installer.profile;

  @override
  String get flutterInstallLabel => prettyPath(paths.flutterInstallDir);

  @override
  String? get shellProfileLabel =>
      _profile.path == null ? null : prettyPath(_profile.path!);

  @override
  List<String> get manualPathLines {
    if (_profile.isSupported) return const [];
    return [
      if (_record[ToolId.flutter]?.path case final root?)
        flutterPathLine(p.join(root, 'bin'), home: paths.home),
      if (_record.owns(ToolId.serverpodCli))
        dartInstallPathLine(paths.dartInstallBinDir, home: paths.home),
    ];
  }

  @override
  Future<void> refreshDeep() => refresh(deep: true);

  /// Re-probes every tool. [deep] enumerates all candidates — used by the Tools
  /// tab; the startup path uses the fast form.
  Future<void> refresh({bool deep = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    notifyListeners();
    try {
      _current = await Toolchain.resolve(
        manifest: manifest,
        paths: paths,
        record: _record,
        deep: deep,
        sandbox: probeSandbox,
      );
    } catch (e) {
      debugPrint('ToolchainController: refresh failed: $e');
    } finally {
      _refreshing = false;
      _notify();
    }
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel?.cancel();
    _installer?.close();
    super.dispose();
  }
}
