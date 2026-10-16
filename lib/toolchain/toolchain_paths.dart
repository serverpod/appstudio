import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/host.dart';

/// Directory name under `~/Library/Application Support` (`%APPDATA%` on
/// Windows).
const kAppSupportDirName = 'App Studio';

/// What the directory was called before the product was renamed. Only ever
/// deleted now — see [ToolchainPaths.legacyPaths].
const kLegacyAppSupportDirName = 'AppStudio';

/// Every path the toolchain reads or writes.
///
/// Deliberately built from the home directory rather than `path_provider`,
/// which resolves to `~/Library/Application Support/dev.serverpod.appstudio` —
/// a bundle id, not a name anyone recognises in Finder.
class ToolchainPaths {
  const ToolchainPaths({
    required this.home,
    required this.appSupportRoot,
    this._host,
  });

  /// Resolves from the home directory (`HOME`, or `USERPROFILE` on Windows).
  /// Falls back to a temp dir so a missing home degrades to "nothing
  /// installed" instead of throwing during startup.
  factory ToolchainPaths.resolve({HostPlatform? host}) {
    final resolvedHost = host ?? currentHost;
    final home =
        resolvedHost.homeFrom(Platform.environment) ??
        Directory.systemTemp.path;
    return ToolchainPaths.forHome(home, host: resolvedHost);
  }

  factory ToolchainPaths.forHome(String home, {HostPlatform? host}) {
    final resolvedHost = host ?? currentHost;
    return ToolchainPaths(
      home: home,
      appSupportRoot: resolvedHost.isWindows
          ? resolvedHost.path.join(
              home,
              'AppData',
              'Roaming',
              kAppSupportDirName,
            )
          : resolvedHost.path.join(
              home,
              'Library',
              'Application Support',
              kAppSupportDirName,
            ),
      host: resolvedHost,
    );
  }

  final String home;

  /// App Studio's own data. No tools live here any more.
  final String appSupportRoot;

  final HostPlatform? _host;

  /// The machine these paths are for.
  HostPlatform get host => _host ?? currentHost;

  p.Context get _path => host.path;

  /// Where a Flutter SDK App Studio installs goes: the directory Flutter's own
  /// instructions extract into (`~/develop/flutter` on macOS,
  /// `%USERPROFILE%\develop\flutter` on Windows), so the result is
  /// indistinguishable from an install done by hand.
  String get flutterInstallDir => _path.join(home, 'develop', 'flutter');

  /// Where `dart install` puts executables.
  String get dartInstallBinDir => host.isWindows
      ? _path.join(home, 'AppData', 'Local', 'Dart', 'install', 'bin')
      : _path.join(
          home,
          'Library',
          'Application Support',
          'Dart',
          'install',
          'bin',
        );

  /// The pub cache when `PUB_CACHE` does not say otherwise.
  String get defaultPubCache => host.isWindows
      ? _path.join(home, 'AppData', 'Local', 'Pub', 'Cache')
      : _path.join(home, '.pub-cache');

  /// The Serverpod CLI's own state directory. The install record lives here
  /// too, because it is about Serverpod tooling rather than about App Studio.
  String get serverpodStateDir => _path.join(home, '.serverpod');

  /// What App Studio installed, and which `PATH` lines it added for it.
  String get installRecordFile =>
      _path.join(serverpodStateDir, 'app_studio_installs.json');

  /// Scratch space for the Flutter archive while it downloads.
  String get downloadsDir => _path.join(appSupportRoot, 'downloads');

  // -- legacy ---------------------------------------------------------------
  //
  // Only macOS builds ever shipped their own toolchain, so there is nothing
  // to find, or remove, anywhere else.

  /// Where earlier builds kept their own copies of every tool.
  String get legacyToolchainRoot => _path.join(appSupportRoot, 'toolchain');

  /// Where earlier builds wrote wrapper scripts, for the shell `PATH` block.
  String get legacyShimDir => _path.join(appSupportRoot, 'bin');

  /// Everything a build before this one may have left behind for tools. The
  /// pre-rename directory goes whole: nothing current reads it.
  List<String> get legacyPaths => host.isMacOS
      ? [
          legacyToolchainRoot,
          legacyShimDir,
          _path.join(_path.dirname(appSupportRoot), kLegacyAppSupportDirName),
        ]
      : const [];

  /// Every rc file an earlier build could have put its `PATH` block in.
  List<String> get legacyShellFiles => host.isMacOS
      ? [
          _path.join(home, '.zshrc'),
          _path.join(home, '.bash_profile'),
          _path.join(home, '.profile'),
        ]
      : const [];
}
