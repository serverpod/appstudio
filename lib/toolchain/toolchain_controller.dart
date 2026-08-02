import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'install_progress.dart';
import 'shell_path_integration.dart';
import 'shim_writer.dart';
import 'tool_status.dart';
import 'tool_version.dart';
import 'toolchain.dart';
import 'toolchain_installer.dart';
import 'toolchain_manifest.dart';
import 'toolchain_paths.dart';
import 'toolchain_requirements.dart';

/// Owns the resolved [Toolchain] and re-resolves it on demand.
///
/// Consumers hold the controller, not a `Toolchain`, and read [current] at call
/// time. Capturing the value would strand them on a snapshot taken before the
/// user installed anything.
class ToolchainController extends ChangeNotifier {
  ToolchainController({
    required Toolchain initial,
    required this.manifest,
    required this.paths,
    required ToolchainRequirements requirements,
  })  : _current = initial,
        // The field is mutable and private; an initializing formal would leak
        // the underscore into the named-argument list.
        // ignore: prefer_initializing_formals
        _requirements = requirements;

  /// Resolves everything needed to start. Never throws: a failure here would
  /// stop the app from launching, and "no tools" is a state the UI can explain.
  static Future<ToolchainController> create() async {
    final paths = ToolchainPaths.resolve();
    ToolManifest? manifest;
    try {
      manifest = await ToolManifest.loadBaked(rootBundle.loadString);
    } catch (e) {
      debugPrint('ToolchainController: could not load the baked manifest: $e');
    }
    final requirements =
        await ToolchainRequirements.load(paths.requirementsFile);

    if (manifest == null) {
      // Without a manifest nothing can be resolved or offered for install.
      throw StateError('Missing $kBakedManifestAsset');
    }

    Toolchain toolchain;
    try {
      toolchain = await Toolchain.resolve(
        manifest: manifest,
        requirements: requirements,
        paths: paths,
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
      requirements: requirements,
    );
  }

  final ToolManifest manifest;
  final ToolchainPaths paths;

  Toolchain _current;
  ToolchainRequirements _requirements;
  bool _refreshing = false;
  bool _disposed = false;

  ToolchainInstaller? _installer;
  InstallProgress? _progress;
  CancelToken? _cancel;
  String? _installError;

  Toolchain get current => _current;
  ToolchainInventory get inventory => _current.inventory;
  ToolchainRequirements get requirements => _requirements;
  bool get isRefreshing => _refreshing;

  /// Non-null while an install is running, and until the next one starts.
  InstallProgress? get progress => _progress;
  bool get isInstalling => _progress != null && !_progress!.isDone;
  String? get installError => _installError;

  /// Blocks a second install and the "remove" buttons while work is in flight.
  bool get isBusy => isInstalling || _refreshing;

  ToolchainInstaller get _requireInstaller =>
      _installer ??= ToolchainInstaller(paths: paths, manifest: manifest);

  /// Clears crashed installs left behind by a previous run. Cheap; fire and
  /// forget at startup.
  Future<void> collectGarbage() => _requireInstaller.collectGarbage();

  /// Downloads and installs everything required that we can supply.
  Future<void> installMissing() =>
      install([for (final t in inventory.installable) t.id]);

  Future<void> install(List<ToolId> ids) async {
    if (isInstalling) return;
    final specs = [
      for (final id in ids)
        if (manifest[id] case final spec?)
          if (spec.artifactForCurrentPlatform != null) spec,
    ];
    if (specs.isEmpty) return;

    _installError = null;
    _cancel = CancelToken();
    _progress = InstallProgress(
      tools: [
        for (final spec in specs)
          ToolProgress(
            id: spec.id,
            phase: ToolPhase.queued,
            totalBytes: spec.artifactForCurrentPlatform!.downloadBytes,
          ),
      ],
      startedAt: DateTime.now(),
    );
    notifyListeners();

    await _requireInstaller.installAll(
      specs,
      cancel: _cancel,
      onProgress: (progress) {
        _progress = progress;
        notifyListeners();
      },
    );

    final failed = _progress?.tools.where((t) => t.phase == ToolPhase.failed);
    if (failed != null && failed.isNotEmpty) {
      _installError = failed.first.error ?? 'Some tools could not be installed.';
    }
    _cancel = null;
    // Pick up whatever landed, even on partial failure.
    await refresh(deep: true);
  }

  void cancelInstall() {
    _cancel?.cancel();
    notifyListeners();
  }

  Future<void> uninstall(ToolId id) async {
    final spec = manifest[id];
    if (spec == null || isBusy) return;
    await _requireInstaller.uninstall(spec);
    await refresh(deep: true);
  }

  // -- shell PATH -----------------------------------------------------------

  ShellPathIntegration get shellPath => ShellPathIntegration(
        binDir: paths.shimBinDir,
        target: ShellTarget.resolve(),
      );

  ShellPathState get shellPathState => _shellPathState;
  ShellPathState _shellPathState = ShellPathState.absent;

  Future<void> refreshShellPathState() async {
    _shellPathState = await shellPath.state();
    notifyListeners();
  }

  /// Adds or removes the managed block in the user's shell config.
  ///
  /// App Studio does not need this — it sets PATH for everything it spawns.
  /// It exists so an external editor or AI agent can find the tools, which is
  /// why it is opt-in and never implied by installing.
  Future<String?> setShellPathEnabled(bool enabled, {bool force = false}) async {
    try {
      if (enabled) {
        await ShimWriter(binDir: paths.shimBinDir).write(_current);
        await shellPath.enable(force: force);
      } else {
        await shellPath.disable();
        await ShimWriter(binDir: paths.shimBinDir).removeAll();
      }
      await refreshShellPathState();
      return null;
    } on ShellPathException catch (e) {
      await refreshShellPathState();
      return e.message;
    } catch (e) {
      return '$e';
    }
  }

  /// Keeps the shims pointing at what is actually installed.
  Future<void> _refreshShimsIfEnabled() async {
    if (_shellPathState != ShellPathState.present) return;
    try {
      await ShimWriter(binDir: paths.shimBinDir).write(_current);
    } catch (e) {
      debugPrint('ToolchainController: could not refresh shims: $e');
    }
  }

  /// Runs `dart pub cache clean`, the sanctioned way to empty `~/.pub-cache`.
  ///
  /// Separate from [uninstallAll] on purpose: that cache belongs to every Dart
  /// project on the machine, so emptying it is never implied by removing our
  /// tools. Returns an error message, or null on success.
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

  /// Removes every managed tool. Host copies and `~/.pub-cache` are untouched.
  Future<void> uninstallAll() async {
    if (isBusy) return;
    await _requireInstaller.uninstallAll();
    _progress = null;
    _installError = null;
    await refresh(deep: true);
  }

  /// Re-probes every tool. [deep] enumerates all candidates — used by the Tools
  /// Manager, which shows alternatives; the startup path uses the fast form.
  Future<void> refresh({bool deep = false}) async {
    if (_refreshing) return;
    _refreshing = true;
    notifyListeners();
    try {
      _current = await Toolchain.resolve(
        manifest: manifest,
        requirements: _requirements,
        paths: paths,
        deep: deep,
      );
    } catch (e) {
      debugPrint('ToolchainController: refresh failed: $e');
    } finally {
      _refreshing = false;
      _notify();
    }
    // Shims embed absolute paths, so they go stale after an install or removal.
    await _refreshShimsIfEnabled();
  }

  /// Raises (or clears) the minimum version the user will accept for a tool,
  /// then re-resolves so the change is visible immediately.
  Future<void> setMinimumVersion(ToolId id, ToolVersion? version) async {
    _requirements = _requirements.withMinimum(id, version);
    await _requirements.save(paths.requirementsFile);
    await refresh(deep: true);
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
