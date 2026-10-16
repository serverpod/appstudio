import 'dart:io';

import '../platform/host.dart';
import 'install_record.dart';
import 'tool_probe.dart';
import 'tool_status.dart';
import 'toolchain_manifest.dart';
import 'toolchain_paths.dart';

/// A resolved view of the tools App Studio needs, built from a
/// [ToolchainInventory].
///
/// Every executable getter is nullable — a bare command name would only defer
/// the failure to `Process.start`, where it surfaces as an unexplainable crash.
class Toolchain {
  const Toolchain(this.inventory, {this._host});

  final ToolchainInventory inventory;

  final HostPlatform? _host;

  /// The machine the tools are on.
  HostPlatform get host => _host ?? currentHost;

  ToolCandidate? resolvedTool(ToolId id) => inventory[id]?.resolved;

  bool isSatisfied(ToolId id) => inventory.isSatisfied(id);

  bool get isComplete => inventory.isComplete;

  String? get flutterRoot => resolvedTool(ToolId.flutter)?.facts['flutterRoot'];
  String? get flutterExecutable => resolvedTool(ToolId.flutter)?.executable;

  /// Comes from the resolved Flutter SDK — Dart is never installed separately.
  String? get dartExecutable =>
      resolvedTool(ToolId.flutter)?.facts['dartExecutable'];

  String? get serverpodExecutable =>
      resolvedTool(ToolId.serverpodCli)?.executable;

  /// Why [id] cannot be used right now, or null when it is fine.
  ///
  /// Spawn sites call this *before* `Process.start` so a missing tool reads as
  /// an explanation with a fix, not a `ProcessException`.
  String? unavailableReason(ToolId id) {
    final status = inventory[id];
    if (status == null) return '${id.displayName} is not configured.';
    if (status.isSatisfied) return null;

    const fix = 'Open Settings → Tools to install it.';
    final rejected = status.bestRejected;
    if (rejected == null || rejected.reason == null) {
      return '${id.displayName} is not installed. $fix';
    }
    return '${id.displayName}: ${rejected.reason}. $fix';
  }

  /// Directories prepended to `PATH` for every spawned process, highest
  /// priority first, so the copies we resolved win over whatever else the
  /// user's `PATH` holds.
  List<String> get binPathPrefix {
    final dirs = <String>[];
    void add(String? executable) {
      if (executable == null) return;
      final dir = host.path.dirname(executable);
      if (!dirs.contains(dir)) dirs.add(dir);
    }

    add(flutterExecutable);
    add(serverpodExecutable);
    return dirs;
  }

  /// The environment of every process App Studio spawns: [parent] (this
  /// process's own, by default) with the resolved tools first on `PATH`.
  ///
  /// On Windows the copy keeps the parent's case-insensitive keys, so the
  /// `Path` the system set is the one rewritten here rather than shadowed by a
  /// second `PATH`.
  Map<String, String> processEnvironment({Map<String, String>? parent}) {
    final env = host.copyEnvironment(parent ?? Platform.environment);

    final pathParts = <String>[
      ...binPathPrefix,
      if (env['PATH'] case final existing?)
        ...existing.split(host.pathListSeparator),
    ];
    env['PATH'] = pathParts
        .where((e) => e.isNotEmpty)
        .join(host.pathListSeparator);

    final root = flutterRoot;
    if (root != null) {
      env['FLUTTER_ROOT'] = root;
      // serverpod_cli (AOT) resolves the SDK via DART_SDK or by probing `dart`
      // on PATH. Pin explicitly so compile/run never pick another copy.
      final dartSdk = host.path.join(root, 'bin', 'cache', 'dart-sdk');
      if (Directory(dartSdk).existsSync()) {
        env['DART_SDK'] = dartSdk;
      }
    }

    // PUB_CACHE is deliberately NOT set. package_config.json stores absolute
    // paths into the cache, so pointing App Studio at a private one would make
    // every switch to an external editor re-resolve the project.

    env['TERM'] = 'xterm-256color';
    env['COLORTERM'] = 'truecolor';
    env['COLORFGBG'] = '0;15';
    return env;
  }

  /// Probes this Mac and builds a toolchain. [deep] enumerates all candidates
  /// for the Tools tab; the default stops at the first satisfied one per tool
  /// because this runs before the first frame.
  static Future<Toolchain> resolve({
    required ToolManifest manifest,
    ToolchainPaths? paths,
    InstallRecord? record,
    bool deep = false,
    ProbeSandbox? sandbox,
  }) async {
    final resolvedPaths = paths ?? ToolchainPaths.resolve();
    final probe = ToolProbe(
      paths: resolvedPaths,
      manifest: manifest,
      record:
          record ?? await InstallRecord.load(resolvedPaths.installRecordFile),
      sandbox: sandbox,
    );
    return Toolchain(
      await probe.inventory(deep: deep),
      host: resolvedPaths.host,
    );
  }
}
