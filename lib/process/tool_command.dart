import 'dart:io';

import '../platform/host.dart';

/// An executable and its arguments, ready for `Process.start`.
class ToolCommand {
  const ToolCommand(this.executable, this.arguments);

  final String executable;
  final List<String> arguments;

  @override
  String toString() => [executable, ...arguments].join(' ');
}

/// How to start [executable] with [arguments] on [host].
///
/// On macOS and Linux this is the command as given. On Windows the tools
/// App Studio runs are mostly batch files — `flutter.bat`, and the
/// `serverpod.bat` that `dart install` writes — and a batch file's arguments
/// are re-read by `cmd.exe`. `Process.start('x.bat', ['a&b'])` runs `b` as a
/// second command, and a path with a space breaks `runInShell`, so:
///
/// - **A `dart install` launcher is skipped.** It is two lines naming the
///   real `.exe`, which is started directly and gets its arguments exactly.
/// - **Any other batch file only takes arguments `cmd.exe` cannot
///   reinterpret** — no spaces, quotes or shell metacharacters. App Studio
///   only ever hands `flutter.bat` fixed words (`pub get`, `--version`);
///   paths travel as the working directory. Anything else is refused with
///   [UnsafeBatchArgumentException] rather than started.
ToolCommand resolveToolCommand(
  String executable,
  List<String> arguments, {
  HostPlatform? host,
}) {
  final resolvedHost = host ?? currentHost;
  if (!resolvedHost.isWindows) return ToolCommand(executable, arguments);

  final extension = resolvedHost.path.extension(executable).toLowerCase();
  if (extension != '.bat' && extension != '.cmd') {
    return ToolCommand(executable, arguments);
  }

  final target = dartInstallLauncherTarget(executable);
  if (target != null) return ToolCommand(target, arguments);

  for (final argument in arguments) {
    if (!_batchSafeArgument.hasMatch(argument)) {
      throw UnsafeBatchArgumentException(executable, argument);
    }
  }
  return ToolCommand(executable, arguments);
}

/// Letters, digits and the punctuation of flags and paths without spaces.
/// Deliberately an allow-list: `cmd.exe` gives meaning to `& | < > ^ % ! ( )`
/// and quotes, and splits on whitespace.
final _batchSafeArgument = RegExp(r'^[A-Za-z0-9_\-.:/\\@+=,]+$');

/// The `.exe` a `dart install` launcher at [batchFile] wraps, or null when
/// [batchFile] is not one or its target is gone.
///
/// The launcher reads
///
/// ```bat
/// @ECHO OFF
/// REM target_file_path_marker
/// "C:\…\app-bundles\serverpod_cli\hosted\4.1.0\bundle\bin\serverpod.exe" %*
/// EXIT /B %ERRORLEVEL%
/// ```
String? dartInstallLauncherTarget(String batchFile) {
  final List<String> lines;
  try {
    lines = File(batchFile).readAsLinesSync();
  } on FileSystemException {
    return null;
  }
  final marker = lines.indexWhere(
    (line) => line.contains('target_file_path_marker'),
  );
  if (marker < 0 || marker + 1 >= lines.length) return null;
  final match = _launcherLine.firstMatch(lines[marker + 1].trim());
  final target = match?.group(1);
  if (target == null || !File(target).existsSync()) return null;
  return target;
}

final _launcherLine = RegExp(r'^"([^"]+\.exe)"\s+%\*$', caseSensitive: false);

/// A batch file was about to receive an argument `cmd.exe` would reinterpret.
class UnsafeBatchArgumentException implements Exception {
  const UnsafeBatchArgumentException(this.batchFile, this.argument);

  final String batchFile;
  final String argument;

  @override
  String toString() =>
      'Refusing to pass "$argument" to $batchFile: cmd.exe would not hand it '
      'over intact.';
}
