import 'dart:io';

import 'package:path/path.dart' as p;

import 'tool_probe.dart';
import 'tool_status.dart';
import 'toolchain_manifest.dart';
import 'toolchain_paths.dart';
import 'toolchain_requirements.dart';

/// A resolved view of the tools App Studio needs, built from a
/// [ToolchainInventory].
///
/// Resolution is **per tool**: a missing OpenCode no longer invalidates
/// Flutter, and each executable can come from a different source. Every
/// executable getter is nullable — a bare command name would only defer the
/// failure to `Process.start`, where it surfaces as an unexplainable crash.
class Toolchain {
  const Toolchain(this.inventory);

  final ToolchainInventory inventory;

  ToolCandidate? resolvedTool(ToolId id) => inventory[id]?.resolved;

  ToolSource? sourceOf(ToolId id) => resolvedTool(id)?.source;

  bool isSatisfied(ToolId id) => inventory.isSatisfied(id);

  bool get isComplete => inventory.isComplete;

  String? get flutterRoot => resolvedTool(ToolId.flutter)?.facts['flutterRoot'];
  String? get flutterExecutable => resolvedTool(ToolId.flutter)?.executable;

  /// Comes from the resolved Flutter SDK — Dart is never installed separately.
  String? get dartExecutable =>
      resolvedTool(ToolId.flutter)?.facts['dartExecutable'];

  String? get serverpodExecutable =>
      resolvedTool(ToolId.serverpodCli)?.executable;
  String? get opencodeExecutable => resolvedTool(ToolId.opencode)?.executable;
  String? get gitExecutable => resolvedTool(ToolId.git)?.executable;
  String? get otoolExecutable => resolvedTool(ToolId.llvmTools)?.executable;

  String? get flutterVersion =>
      resolvedTool(ToolId.flutter)?.detectedVersion?.toString();
  String? get serverpodCliVersion =>
      resolvedTool(ToolId.serverpodCli)?.detectedVersion?.toString();
  String? get opencodeVersion =>
      resolvedTool(ToolId.opencode)?.detectedVersion?.toString();
  String? get gitVersion =>
      resolvedTool(ToolId.git)?.detectedVersion?.toString();

  /// Short status for the toolbar badge.
  String get badgeLabel {
    final missing = inventory.missingRequired.length;
    if (missing > 0) return '$missing missing';
    final source = sourceOf(ToolId.flutter);
    final version = flutterVersion;
    if (source == null) return 'no tools';
    return version == null
        ? source.label.toLowerCase()
        : '${source.label.toLowerCase()} $version';
  }

  /// Why [id] cannot be used right now, or null when it is fine.
  ///
  /// Spawn sites call this *before* `Process.start` so a missing tool reads as
  /// an explanation with a fix, not a `ProcessException`.
  String? unavailableReason(ToolId id) {
    final status = inventory[id];
    if (status == null) return '${id.displayName} is not configured.';
    if (status.isSatisfied) return null;

    const fix = 'Open Tools → Manage Tools to install it.';
    final rejected = status.bestRejected;
    if (rejected == null || rejected.reason == null) {
      return '${id.displayName} is not installed. $fix';
    }
    return '${id.displayName}: ${rejected.reason}. $fix';
  }

  /// Directories prepended to `PATH` for every spawned process, highest
  /// priority first. Derived from the resolved executables so a host tool and
  /// a managed tool are handled identically.
  List<String> get binPathPrefix {
    final dirs = <String>[];
    void add(String? executable) {
      if (executable == null) return;
      final dir = p.dirname(executable);
      // /usr/bin must never be prepended — it would put the CLT shims ahead of
      // the real tools we just resolved.
      if (dir == kCltShimDir || dirs.contains(dir)) return;
      dirs.add(dir);
    }

    // Real otool / install_name_tool and git before anything else, so Apple's
    // stubs are never reached.
    add(otoolExecutable);
    add(gitExecutable);
    add(flutterExecutable);
    add(serverpodExecutable);
    return dirs;
  }

  Map<String, String> processEnvironment() {
    final env = Map<String, String>.from(Platform.environment);

    final pathParts = <String>[
      ...binPathPrefix,
      if (env['PATH'] case final existing?) ...existing.split(':'),
    ];
    env['PATH'] = pathParts.where((e) => e.isNotEmpty).join(':');

    final root = flutterRoot;
    if (root != null) {
      env['FLUTTER_ROOT'] = root;
      // serverpod_cli (AOT) resolves the SDK via DART_SDK or by probing `dart`
      // on PATH. Pin explicitly so compile/run never pick a host stub.
      final dartSdk = p.join(root, 'bin', 'cache', 'dart-sdk');
      if (Directory(dartSdk).existsSync()) {
        env['DART_SDK'] = dartSdk;
      }
    }

    // Prefer pinned engine artifacts over git triangulation. Only ever set for
    // an SDK we control: a host SDK may sit at a different revision than its
    // engine.version implies after a channel switch, and forcing the variable
    // would make it fetch artifacts for the wrong engine.
    final engineVersion = resolvedTool(ToolId.flutter)?.facts['engineVersion'];
    if (engineVersion != null && engineVersion.isNotEmpty) {
      env['FLUTTER_PREBUILT_ENGINE_VERSION'] = engineVersion;
    }

    // Only for a git we ship — a Homebrew git finds its own libexec, and
    // overriding it would break that install.
    final gitExecPath = resolvedTool(ToolId.git)?.facts['gitExecPath'];
    if (gitExecPath != null && gitExecPath.isNotEmpty) {
      env['GIT_EXEC_PATH'] = gitExecPath;
    }

    // The prebuilt Serverpod bundle ships sqlite dylibs next to the binary.
    // Its @rpath already finds them; this is insurance.
    final libDir = resolvedTool(ToolId.serverpodCli)?.facts['libDir'];
    if (libDir != null && libDir.isNotEmpty) {
      final existing = env['DYLD_LIBRARY_PATH'];
      env['DYLD_LIBRARY_PATH'] =
          existing == null || existing.isEmpty ? libDir : '$libDir:$existing';
    }

    // PUB_CACHE is deliberately NOT set. package_config.json stores absolute
    // paths into the cache, so pointing App Studio at a private one would make
    // every switch to an external editor re-resolve the project.

    env['TERM'] = 'xterm-256color';
    env['COLORTERM'] = 'truecolor';
    env['COLORFGBG'] = '0;15';
    return env;
  }

  /// Probes every source and builds a toolchain. [deep] enumerates all
  /// candidates for the Tools Manager; the default stops at the first
  /// satisfied one per tool because this runs before the first frame.
  static Future<Toolchain> resolve({
    ToolManifest? manifest,
    ToolchainRequirements? requirements,
    ToolchainPaths? paths,
    bool deep = false,
  }) async {
    final resolvedPaths = paths ?? ToolchainPaths.resolve();
    final resolvedManifest = manifest ?? await _loadManifestFromDisk();
    final probe = ToolProbe(
      paths: resolvedPaths,
      manifest: resolvedManifest,
      requirements:
          requirements ?? await ToolchainRequirements.load(resolvedPaths.requirementsFile),
      devRepoRoot: devRepoToolchainRoot(),
      bundledRoot: bundledToolchainRoot(),
    );
    return Toolchain(await probe.inventory(deep: deep));
  }

  /// Fallback used when no manifest is injected — reads the asset straight
  /// from disk so this works in tests and plain Dart scripts too.
  static Future<ToolManifest> _loadManifestFromDisk() async {
    for (final candidate in [
      p.join(Directory.current.path, kBakedManifestAsset),
      if (devRepoRoot() case final root?) p.join(root, kBakedManifestAsset),
    ]) {
      final file = File(candidate);
      if (await file.exists()) {
        final manifest = ToolManifest.tryParse(await file.readAsString());
        if (manifest != null) return manifest;
      }
    }
    throw StateError('Could not load $kBakedManifestAsset');
  }
}

/// `<repo>/toolchain` when running from a source checkout, else null.
String? devRepoToolchainRoot() {
  final root = devRepoRoot();
  if (root == null) return null;
  final candidate = p.join(root, 'toolchain');
  return Directory(candidate).existsSync() ? candidate : null;
}

/// Walks up from the cwd looking for the repo root (pubspec.yaml + toolchain/).
String? devRepoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync() &&
        Directory(p.join(dir.path, 'toolchain')).existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// `App Studio.app/Contents/Resources/toolchain`, kept so an offline/enterprise
/// build that still embeds the toolchain keeps working.
String? bundledToolchainRoot() {
  final exe = File(Platform.resolvedExecutable);
  final contents = exe.parent.parent.path;
  final candidate = p.join(contents, 'Resources', 'toolchain');
  return Directory(candidate).existsSync() ? candidate : null;
}
