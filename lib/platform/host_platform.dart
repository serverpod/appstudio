import 'dart:collection';

import 'package:path/path.dart' as p;

/// The operating systems App Studio knows how to run on.
enum HostOs { macos, windows, linux }

/// Everything that differs between the machines App Studio runs on, in one
/// place: where the home directory comes from, how paths and `PATH` are
/// written, what tools are called on disk, and how a child's environment is
/// built.
///
/// Pure — no `dart:io` — so a test can build a Windows host on a Mac and the
/// other way round, and every rule here is checked on whichever machine runs
/// the suite. `currentHost` (`host.dart`) is the one for the running process.
///
/// macOS is the reference: for [HostOs.macos] every member answers exactly what
/// the code it replaced did, so moving a call site onto it changes nothing on
/// a Mac.
class HostPlatform {
  const HostPlatform(this.os) : _path = null;

  /// The host this process runs on, with `package:path`'s own context — the
  /// one that knows the working directory. Only `host.dart` builds this.
  HostPlatform.native(this.os, p.Context path) : _path = path;

  static const macos = HostPlatform(HostOs.macos);
  static const windows = HostPlatform(HostOs.windows);
  static const linux = HostPlatform(HostOs.linux);

  /// From `Platform.operatingSystem`. Anything unknown is treated as Linux,
  /// the closest POSIX relative.
  factory HostPlatform.fromOperatingSystem(String name) => switch (name) {
    'macos' => macos,
    'windows' => windows,
    _ => linux,
  };

  final HostOs os;

  final p.Context? _path;

  bool get isWindows => os == HostOs.windows;
  bool get isMacOS => os == HostOs.macos;

  /// Path rules for this host, whatever the machine running the code. On a
  /// Mac, `HostPlatform.macos.path.join` is `p.join`.
  p.Context get path => _path ?? (isWindows ? _windowsPath : _posixPath);

  static final _posixPath = p.Context(style: p.Style.posix, current: '/');
  static final _windowsPath = p.Context(
    style: p.Style.windows,
    current: r'C:\',
  );

  /// Separates the entries of `PATH`.
  String get pathListSeparator => isWindows ? ';' : ':';

  /// The user's home directory as [environment] gives it. Windows has no
  /// `HOME`; `USERPROFILE` is what the Serverpod CLI and Dart read there.
  String? homeFrom(Map<String, String> environment) {
    final home = isWindows
        ? environment['USERPROFILE'] ?? environment['HOME']
        : environment['HOME'];
    return home == null || home.isEmpty ? null : home;
  }

  @override
  bool operator ==(Object other) => other is HostPlatform && other.os == os;

  @override
  int get hashCode => os.hashCode;

  @override
  String toString() => 'HostPlatform(${os.name})';

  // -- tools on disk --------------------------------------------------------

  /// `bin/<this>` in a Flutter SDK. On Windows `bin/flutter` also exists, but
  /// it is the shell script for Git Bash; `flutter.bat` is the launcher.
  String get flutterLauncherName => isWindows ? 'flutter.bat' : 'flutter';

  /// `bin/cache/dart-sdk/bin/<this>` in a Flutter SDK.
  String get dartExecutableName => isWindows ? 'dart.exe' : 'dart';

  /// What `dart install` (and `dart pub global activate`) writes for a
  /// package executable named [name].
  String installedExecutableName(String name) => isWindows ? '$name.bat' : name;

  // -- PATH -----------------------------------------------------------------

  /// The entries of a `PATH` value, empty ones dropped.
  List<String> splitPathList(String? value) => value == null
      ? const []
      : value.split(pathListSeparator).where((e) => e.isNotEmpty).toList();

  /// The file names [command] may have on disk, in the order a shell tries
  /// them. On Windows that is `PATHEXT`, and a bare name is never run; a name
  /// that already carries an extension is taken as it is.
  List<String> executableNames(String command, {String? pathExt}) {
    if (!isWindows) return [command];
    if (path.extension(command).isNotEmpty) return [command];
    final extensions =
        (pathExt == null || pathExt.isEmpty ? _defaultPathExt : pathExt)
            .split(';')
            .where((e) => e.isNotEmpty);
    return [for (final ext in extensions) '$command${ext.toLowerCase()}'];
  }

  static const _defaultPathExt = '.COM;.EXE;.BAT;.CMD';

  /// Whether two paths name the same place. Windows paths compare without
  /// regard to case, as the filesystem does.
  bool pathEquals(String a, String b) {
    final left = path.normalize(a);
    final right = path.normalize(b);
    return isWindows
        ? left.toLowerCase() == right.toLowerCase()
        : left == right;
  }

  // -- environment ----------------------------------------------------------

  /// A mutable copy of [environment] that looks keys up the way this host
  /// does. Windows variable names are case-insensitive — the parent's map
  /// holds `Path`, and a plain `Map.from` would let `env['PATH'] = …` add a
  /// second, conflicting entry instead of replacing it.
  Map<String, String> copyEnvironment(Map<String, String> environment) {
    if (!isWindows) return Map<String, String>.from(environment);
    final copy = LinkedHashMap<String, String>(
      equals: (a, b) => a.toUpperCase() == b.toUpperCase(),
      hashCode: (key) => key.toUpperCase().hashCode,
    );
    copy.addAll(environment);
    return copy;
  }

  /// Variables a Windows child cannot do without, even when it is otherwise
  /// started with an environment of our choosing
  /// (`includeParentEnvironment: false`): without `SystemRoot` Winsock and
  /// most of the system DLLs fail to initialise, and without `PATHEXT`,
  /// `TEMP` and the profile folders tools fall back to odd defaults.
  static const windowsEssentialVariables = [
    'SystemRoot',
    'windir',
    'ComSpec',
    'PATHEXT',
    'TEMP',
    'TMP',
    'USERPROFILE',
    'LOCALAPPDATA',
    'APPDATA',
    'ProgramData',
    'ProgramFiles',
    'ProgramFiles(x86)',
    'NUMBER_OF_PROCESSORS',
    'PROCESSOR_ARCHITECTURE',
  ];

  /// The essentials of [parent] this host needs in any child environment —
  /// nothing at all on macOS and Linux.
  Map<String, String> essentialEnvironment(Map<String, String> parent) {
    if (!isWindows) return const {};
    final lookup = copyEnvironment(parent);
    return {
      for (final name in windowsEssentialVariables)
        name: ?lookup[name],
    };
  }
}
