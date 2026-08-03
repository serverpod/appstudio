import 'dart:io';

import 'package:path/path.dart' as p;

import 'toolchain_manifest.dart';

/// Directory name under `~/Library/Application Support`.
const kAppSupportDirName = 'App Studio';

/// What the directory was called before the product was renamed. Kept so
/// [ToolchainPaths.migrateLegacyDirectory] can move an existing install rather
/// than stranding up to ~1.9 GB of downloaded tools.
const kLegacyAppSupportDirName = 'AppStudio';

/// Every managed path App Studio owns.
///
/// Deliberately built from `HOME` rather than `path_provider`, which resolves
/// to `~/Library/Application Support/dev.serverpod.appstudio` — a bundle id,
/// not a name anyone recognises in Finder.
class ToolchainPaths {
  const ToolchainPaths(this.appSupportRoot);

  /// Resolves from `HOME`. Falls back to a temp dir so a missing HOME degrades
  /// to "nothing installed" instead of throwing during startup.
  factory ToolchainPaths.resolve() {
    final home = Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      return ToolchainPaths(
        p.join(Directory.systemTemp.path, kAppSupportDirName),
      );
    }
    return ToolchainPaths(
      p.join(home, 'Library', 'Application Support', kAppSupportDirName),
    );
  }

  final String appSupportRoot;

  /// Old location, alongside the current one.
  String get legacyAppSupportRoot =>
      p.join(p.dirname(appSupportRoot), kLegacyAppSupportDirName);

  /// Moves a pre-rename install into place.
  ///
  /// A same-volume rename, so it is instant even with a full toolchain. Returns
  /// true when something was moved. Never throws: failing to migrate must
  /// degrade to "nothing installed", not to a broken launch.
  Future<bool> migrateLegacyDirectory() async {
    if (appSupportRoot == legacyAppSupportRoot) return false;
    try {
      final legacy = Directory(legacyAppSupportRoot);
      if (!await legacy.exists()) return false;
      // Never clobber a real current directory; the user would lose it.
      if (await Directory(appSupportRoot).exists()) return false;
      await legacy.rename(appSupportRoot);
      return true;
    } catch (_) {
      return false;
    }
  }

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
