import 'dart:io';

import 'package:path/path.dart' as p;

import 'toolchain_manifest.dart';

/// Every managed path App Studio owns.
///
/// Deliberately built from `HOME` rather than `path_provider`, which resolves
/// to `~/Library/Application Support/dev.serverpod.appstudio`. The directory
/// this app has always used is `AppStudio`, and moving it would strand the
/// existing pub cache.
class ToolchainPaths {
  const ToolchainPaths(this.appSupportRoot);

  /// Resolves from `HOME`. Falls back to a temp dir so a missing HOME degrades
  /// to "nothing installed" instead of throwing during startup.
  factory ToolchainPaths.resolve() {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      return ToolchainPaths(
        p.join(Directory.systemTemp.path, 'AppStudio'),
      );
    }
    return ToolchainPaths(
      p.join(home, 'Library', 'Application Support', 'AppStudio'),
    );
  }

  final String appSupportRoot;

  String get toolchainRoot => p.join(appSupportRoot, 'toolchain');

  /// Shim wrappers, outside `toolchain/` so "uninstall all" can wipe the
  /// toolchain while leaving a shim that explains what happened.
  String get shimBinDir => p.join(appSupportRoot, 'bin');

  /// Dot-prefixed working directories, skipped by resolution so a crashed
  /// install can never be mistaken for an installed tool.
  String get downloadsDir => p.join(toolchainRoot, '.downloads');
  String get stagingDir => p.join(toolchainRoot, '.staging');
  String get trashDir => p.join(toolchainRoot, '.trash');
  String get lockFile => p.join(toolchainRoot, '.lock');

  String get requirementsFile => p.join(toolchainRoot, 'requirements.json');
  String get installedFile => p.join(toolchainRoot, 'installed.json');
  String get cachedManifestFile => p.join(toolchainRoot, 'manifest.json');

  String installDirFor(ToolSpec spec) =>
      p.join(toolchainRoot, spec.installDir);

  /// True for the scratch directories that resolution must ignore.
  static bool isWorkingDir(String name) => name.startsWith('.');
}
