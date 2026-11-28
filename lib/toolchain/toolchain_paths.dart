import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/host.dart';

/// Directory name under `~/Library/Application Support` (`%APPDATA%` on
/// Windows).
const kAppSupportDirName = 'App Studio';

/// Linux: the directory under `$XDG_DATA_HOME`. It is the GTK application id
/// (`linux/CMakeLists.txt`), because `shared_preferences` already keeps the
/// settings in a directory of that name, so App Studio's own data joins them
/// and there is one directory to remove (specs/linux_port.md, L5).
const kLinuxAppDataDirName = 'dev.serverpod.appstudio';

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
    this._stateHome,
  });

  /// Resolves from the home directory (`HOME`, or `USERPROFILE` on Windows).
  /// Falls back to a temp dir so a missing home degrades to "nothing
  /// installed" instead of throwing during startup.
  factory ToolchainPaths.resolve({HostPlatform? host}) {
    final resolvedHost = host ?? currentHost;
    final home =
        resolvedHost.homeFrom(Platform.environment) ??
        Directory.systemTemp.path;
    return ToolchainPaths.forHome(
      home,
      host: resolvedHost,
      environment: Platform.environment,
    );
  }

  /// [environment] is read only on Linux, for the XDG base directories.
  factory ToolchainPaths.forHome(
    String home, {
    HostPlatform? host,
    Map<String, String> environment = const {},
  }) {
    final resolvedHost = host ?? currentHost;
    final path = resolvedHost.path;
    return ToolchainPaths(
      home: home,
      appSupportRoot: switch (resolvedHost.os) {
        HostOs.windows => path.join(
          home,
          'AppData',
          'Roaming',
          kAppSupportDirName,
        ),
        HostOs.linux => path.join(
          _xdgDir(environment['XDG_DATA_HOME'], path) ??
              path.join(home, '.local', 'share'),
          kLinuxAppDataDirName,
        ),
        HostOs.macos => path.join(
          home,
          'Library',
          'Application Support',
          kAppSupportDirName,
        ),
      },
      host: resolvedHost,
      stateHome: _xdgDir(environment['XDG_STATE_HOME'], path),
    );
  }

  /// An XDG base directory variable, or null when it is unset, empty or
  /// relative — the spec says to ignore a relative one and use the default.
  static String? _xdgDir(String? value, p.Context path) =>
      value != null && value.isNotEmpty && path.isAbsolute(value)
      ? value
      : null;

  final String home;

  /// App Studio's own data. No tools live here any more.
  final String appSupportRoot;

  final HostPlatform? _host;

  /// Linux: `XDG_STATE_HOME` when it was set, for [dartInstallBinDir].
  final String? _stateHome;

  /// The machine these paths are for.
  HostPlatform get host => _host ?? currentHost;

  p.Context get _path => host.path;

  /// Where a Flutter SDK App Studio installs goes: the directory Flutter's own
  /// instructions extract into (`~/develop/flutter` on macOS,
  /// `%USERPROFILE%\develop\flutter` on Windows), so the result is
  /// indistinguishable from an install done by hand.
  String get flutterInstallDir => _path.join(home, 'develop', 'flutter');

  /// Where `dart install` puts executables. On Linux that is under
  /// `$XDG_STATE_HOME` (`~/.local/state`), with a capital D, each one a
  /// symlink into the package's bundle.
  String get dartInstallBinDir => switch (host.os) {
    HostOs.windows => _path.join(
      home,
      'AppData',
      'Local',
      'Dart',
      'install',
      'bin',
    ),
    HostOs.linux => _path.join(
      _stateHome ?? _path.join(home, '.local', 'state'),
      'Dart',
      'install',
      'bin',
    ),
    HostOs.macos => _path.join(
      home,
      'Library',
      'Application Support',
      'Dart',
      'install',
      'bin',
    ),
  };

  /// The pub cache when `PUB_CACHE` does not say otherwise.
  String get defaultPubCache => host.isWindows
      ? _path.join(home, 'AppData', 'Local', 'Pub', 'Cache')
      : _path.join(home, '.pub-cache');

  /// The Serverpod CLI's own state directory. The install record lives here
  /// too, because it is about Serverpod tooling rather than about App Studio.
  String get serverpodStateDir => _path.join(home, '.serverpod');

  /// Where Serverpod's install script (`curl … install.sh | sh`) puts the
  /// Flutter SDK it installs when the machine has none. Not App Studio's: it
  /// is found like any other SDK, and uninstall leaves it alone.
  String get installScriptFlutterDir => _path.join(serverpodStateDir, 'flutter');

  /// What `serverpod doctor --fix` writes, and every shell startup file it
  /// edited sources. Deleting it leaves each of those printing an error.
  String get installScriptEnvFile => _path.join(serverpodStateDir, 'env.sh');

  /// What [serverpodStateDir] holds that is not the CLI's own state, so an
  /// uninstall that takes the CLI keeps it.
  List<String> get keptOnUninstall =>
      [installScriptFlutterDir, installScriptEnvFile];

  /// Windows: App Studio's machine-local data — the preview's CEF cache, which
  /// the runner puts in `%LOCALAPPDATA%\App Studio\CEF` (`windows/runner/
  /// main.cpp`). Null on macOS and Linux, where all of it is under
  /// [appSupportRoot].
  String? get localDataRoot => host.isWindows
      ? _path.join(home, 'AppData', 'Local', kAppSupportDirName)
      : null;

  /// Windows: where `shared_preferences` keeps its file —
  /// `%APPDATA%\<CompanyName>\<ProductName>` from `windows/runner/Runner.rc`.
  /// Null on macOS, where preferences are NSUserDefaults, and on Linux, where
  /// the file is in [appSupportRoot] itself.
  String? get preferencesRoot => host.isWindows
      ? _path.join(home, 'AppData', 'Roaming', 'Serverpod', kAppSupportDirName)
      : null;

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
