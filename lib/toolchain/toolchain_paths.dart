import 'dart:io';

import 'package:path/path.dart' as p;

/// Directory name under `~/Library/Application Support`.
const kAppSupportDirName = 'App Studio';

/// What the directory was called before the product was renamed. Only ever
/// deleted now — see [ToolchainPaths.legacyPaths].
const kLegacyAppSupportDirName = 'AppStudio';

/// Every path the toolchain reads or writes.
///
/// Deliberately built from `HOME` rather than `path_provider`, which resolves
/// to `~/Library/Application Support/dev.serverpod.appstudio` — a bundle id,
/// not a name anyone recognises in Finder.
class ToolchainPaths {
  const ToolchainPaths({required this.home, required this.appSupportRoot});

  /// Resolves from `HOME`. Falls back to a temp dir so a missing HOME degrades
  /// to "nothing installed" instead of throwing during startup.
  factory ToolchainPaths.resolve() {
    final env = Platform.environment['HOME'];
    final home = env == null || env.isEmpty ? Directory.systemTemp.path : env;
    return ToolchainPaths.forHome(home);
  }

  factory ToolchainPaths.forHome(String home) => ToolchainPaths(
        home: home,
        appSupportRoot:
            p.join(home, 'Library', 'Application Support', kAppSupportDirName),
      );

  final String home;

  /// App Studio's own data. No tools live here any more.
  final String appSupportRoot;

  /// Where a Flutter SDK App Studio installs goes: the directory Flutter's own
  /// macOS instructions extract into, so the result is indistinguishable from
  /// an install done by hand.
  String get flutterInstallDir => p.join(home, 'develop', 'flutter');

  /// Where `dart install` puts executables on macOS.
  String get dartInstallBinDir =>
      p.join(home, 'Library', 'Application Support', 'Dart', 'install', 'bin');

  /// The Serverpod CLI's own state directory. The install record lives here
  /// too, because it is about Serverpod tooling rather than about App Studio.
  String get serverpodStateDir => p.join(home, '.serverpod');

  /// What App Studio installed, and which `PATH` lines it added for it.
  String get installRecordFile =>
      p.join(serverpodStateDir, 'app_studio_installs.json');

  /// Scratch space for the Flutter archive while it downloads.
  String get downloadsDir => p.join(appSupportRoot, 'downloads');

  // -- legacy ---------------------------------------------------------------

  /// Where earlier builds kept their own copies of every tool.
  String get legacyToolchainRoot => p.join(appSupportRoot, 'toolchain');

  /// Where earlier builds wrote wrapper scripts, for the shell `PATH` block.
  String get legacyShimDir => p.join(appSupportRoot, 'bin');

  /// Everything a build before this one may have left behind for tools. The
  /// pre-rename directory goes whole: nothing current reads it.
  List<String> get legacyPaths => [
        legacyToolchainRoot,
        legacyShimDir,
        p.join(p.dirname(appSupportRoot), kLegacyAppSupportDirName),
      ];

  /// Every rc file an earlier build could have put its `PATH` block in.
  List<String> get legacyShellFiles => [
        p.join(home, '.zshrc'),
        p.join(home, '.bash_profile'),
        p.join(home, '.profile'),
      ];
}
