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
    required ToolManifest manifest,
    required this.paths,
    required ToolchainRequirements requirements,
  })  : // Both fields are mutable and private; initializing formals would leak
        // the underscores into the named-argument list. The ignore only covers
        // the line after it, so each assignment needs its own.
        // ignore: prefer_initializing_formals
        _manifest = manifest,
        _current = initial,
        // ignore: prefer_initializing_formals
        _requirements = requirements;

  /// Resolves everything needed to start. Never throws: a failure here would
  /// stop the app from launching, and "no tools" is a state the UI can explain.
  static Future<ToolchainController> create() async {
    final paths = ToolchainPaths.resolve();
    // The product was renamed AppStudio → App Studio. Move an existing install
    // instead of stranding it; a same-volume rename, so instant even at 1.9 GB.
    final migrated = await paths.migrateLegacyDirectory();
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

    final cached = await ToolManifest.loadCached(paths.cachedManifestFile);
    if (cached != null && cached.isNewerThan(manifest)) {
      manifest = cached;
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

    final controller = ToolchainController(
      initial: toolchain,
      manifest: manifest,
      paths: paths,
      requirements: requirements,
    );
    if (migrated) {
      // Shims and the shell rc block embed absolute paths that just moved.
      unawaited(controller._repairAfterMigration());
    }
    return controller;
  }

  ToolManifest _manifest;
  ToolManifest get manifest => _manifest;
  final ToolchainPaths paths;

  Toolchain _current;
  ToolchainRequirements _requirements;
  bool _refreshing = false;
  bool _fetchingManifest = false;
  bool _disposed = false;

  ToolchainInstaller? _installer;
  InstallProgress? _progress;
  CancelToken? _cancel;
  String? _installError;
  bool _finalizing = false;

  Toolchain get current => _current;
  @override
  ToolchainInventory get inventory => _current.inventory;
  ToolchainRequirements get requirements => _requirements;
  bool get isRefreshing => _refreshing;

  /// Non-null while an install is running, and until the next one starts.
  @override
  InstallProgress? get progress => _progress;

  /// True from the moment [install] is called until every step it owns has
  /// finished — including the deep re-probe that runs after the last tool
  /// lands. Dropping it the instant the downloads were terminal put the setup
  /// dialog back on its download plan for the second the re-probe took, which
  /// read as the install having been thrown away.
  @override
  bool get isInstalling =>
      _finalizing || (_progress != null && !_progress!.isDone);
  @override
  String? get installError => _installError;

  /// Blocks a second install and the "remove" buttons while work is in flight.
  @override
  bool get isBusy => isInstalling || _refreshing;

  ToolchainInstaller get _requireInstaller =>
      _installer ??= ToolchainInstaller(paths: paths, manifest: _manifest);

  /// Pulls the live manifest from the bucket when it is newer than the current
  /// pin, HEADs each artifact we would download for its current size, then
  /// re-probes so the UI shows what would actually be fetched.
  ///
  /// **A failed manifest fetch is not an error here.** `manifest.json` is an
  /// optional upgrade over the pin baked into the app; it is not published
  /// today, so treating its absence as fatal would mean no first run ever gets
  /// past this. An unreachable *artifact* is fatal — that download is about to
  /// fail — and that is what this reports.
  @override
  Future<String?> preflight() async {
    if (_fetchingManifest || isInstalling) return null;
    _fetchingManifest = true;
    notifyListeners();
    try {
      final fetched = await ToolManifest.fetchPublished(
        _manifest.baseUrl,
        cacheFile: paths.cachedManifestFile,
      );
      if (fetched != null && fetched.isNewerThan(_manifest)) {
        _manifest = fetched;
        _installer = null;
        // Re-resolve before reading `installable`: a newer pin can change which
        // tools qualify, and those are the only ones worth probing.
        await refresh(deep: false);
      }

      final wanted = [for (final t in inventory.installable) t.id];
      if (wanted.isEmpty) return null;

      final probe = await _manifest.probeArtifacts(only: wanted);
      if (!identical(probe.manifest, _manifest)) {
        _manifest = probe.manifest;
        _installer = null;
        // Sizes live on the specs the inventory holds, so the dialog would
        // quote the baked numbers without this.
        await refresh(deep: false);
      }
      if (probe.unreachable.isEmpty) return null;
      return _unreachableMessage(probe.unreachable);
    } catch (e) {
      debugPrint('ToolchainController: preflight failed: $e');
      return 'Could not prepare the download: $e';
    } finally {
      _fetchingManifest = false;
      _notify();
    }
  }

  String _unreachableMessage(List<ToolId> ids) {
    final names = [for (final id in ids) id.displayName];
    final list = switch (names.length) {
      1 => names.single,
      2 => '${names.first} and ${names.last}',
      _ => '${names.take(names.length - 1).join(', ')} and ${names.last}',
    };
    return 'Could not reach the download server for $list. '
        'Check your internet connection and try again.';
  }

  /// Clears crashed installs left behind by a previous run. Cheap; fire and
  /// forget at startup.
  Future<void> collectGarbage() => _requireInstaller.collectGarbage();

  /// Downloads and installs everything required that we can supply.
  @override
  Future<void> installMissing() =>
      install([for (final t in inventory.installable) t.id]);

  @override
  Future<void> install(List<ToolId> ids) async {
    if (isInstalling) return;
    final specs = [
      for (final id in ids)
        if (_manifest[id] case final spec?)
          if (spec.artifactForCurrentPlatform != null) spec,
    ];
    if (specs.isEmpty) return;

    _installError = null;
    _finalizing = true;
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

    try {
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
        _installError =
            failed.first.error ?? 'Some tools could not be installed.';
      }
      _cancel = null;
      // Pick up whatever landed, even on partial failure.
      await refresh(deep: true);
    } finally {
      // A throw here would otherwise leave the UI reporting an install that is
      // no longer running, with no way back to the plan.
      _finalizing = false;
      _notify();
    }
  }

  @override
  void cancelInstall() {
    _cancel?.cancel();
    notifyListeners();
  }

  @override
  Future<void> uninstall(ToolId id) async {
    final spec = _manifest[id];
    if (spec == null || isBusy) return;
    await _requireInstaller.uninstall(spec);
    await refresh(deep: true);
  }

  // -- shell PATH -----------------------------------------------------------

  ShellPathIntegration get shellPath => ShellPathIntegration(
        binDir: paths.shimBinDir,
        target: ShellTarget.resolve(),
      );

  @override
  ShellPathState get shellPathState => _shellPathState;
  ShellPathState _shellPathState = ShellPathState.absent;

  @override
  Future<void> refreshShellPathState() async {
    _shellPathState = await shellPath.state();
    notifyListeners();
  }

  /// Adds or removes the managed block in the user's shell config.
  ///
  /// App Studio does not need this — it sets PATH for everything it spawns.
  /// It exists so an external editor or AI agent can find the tools, which is
  /// why it is opt-in and never implied by installing.
  @override
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

  /// Rewrites everything that hardcoded the pre-rename directory.
  Future<void> _repairAfterMigration() async {
    try {
      await refreshShellPathState();
      if (_shellPathState == ShellPathState.present) {
        // Re-render both the shims and the rc block against the new root.
        await setShellPathEnabled(true);
      } else {
        await ShimWriter(binDir: paths.shimBinDir).write(_current);
      }
      await refresh();
    } catch (e) {
      debugPrint('ToolchainController: post-migration repair failed: $e');
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

  // --- ToolsView -----------------------------------------------------------
  //
  // The tools pane talks to this interface rather than to the controller, so
  // it never imports dart:io and stays previewable. What is left exists only so
  // the widget layer does not have to reach through `paths` and `shellPath` to
  // build strings.

  @override
  Future<void> refreshDeep() => refresh(deep: true);

  @override
  String get shellName => shellPath.target.shell;

  @override
  String get shellRcLabel => prettyPath(shellPath.target.rcPath ?? '');

  @override
  String get shellExportLine => shellPath.exportLine;

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
        manifest: _manifest,
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
