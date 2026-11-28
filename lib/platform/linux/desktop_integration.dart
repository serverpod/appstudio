import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../host.dart';
import 'app_version.dart';
import 'desktop_integration_status.dart';
import 'running_app_image.dart';

export 'app_version.dart';
export 'desktop_integration_status.dart';

/// The GTK application id (`APPLICATION_ID` in `linux/CMakeLists.txt`). The
/// AppImage's desktop entry and icons are named after it, and its
/// `StartupWMClass` is it.
const kLinuxAppId = 'dev.serverpod.appstudio';

/// The key App Studio adds to the desktop entry it writes, so it removes only
/// that one and never an entry Gear Lever or AppImageLauncher wrote.
const kAddedByKey = 'X-AppStudio-AddedBy';
const kAddedByValue = 'appstudio';

/// The version and build of the AppImage App Studio added, written into its
/// entry: the added file is not mounted, so this is the only place to read
/// them from when another copy starts.
const kAddedVersionKey = 'X-AppStudio-Version';
const kAddedBuildKey = 'X-AppStudio-Build';

/// The added AppImage's name: no version in it, so replacing the file keeps
/// the desktop entry valid.
const kAddedAppImageName = 'AppStudio-x86_64.AppImage';

/// The running build's version, from the `version.json` Flutter writes
/// beside the executable (`data/flutter_assets/`). On Linux the updater has
/// no native side to ask.
Future<AppVersion?> readRunningVersion() async {
  try {
    final file = File(
      p.join(
        p.dirname(Platform.resolvedExecutable),
        'data',
        'flutter_assets',
        'version.json',
      ),
    );
    final json = jsonDecode(await file.readAsString());
    if (json is! Map) return null;
    final version = json['version'];
    final build = int.tryParse('${json['build_number']}');
    if (version is! String || build == null) return null;
    return AppVersion(version, build);
  } catch (e) {
    debugPrint('could not read the running version: $e');
    return null;
  }
}

/// What failed while adding App Studio to the app menu, and why.
class DesktopIntegrationException implements Exception {
  const DesktopIntegrationException(this.step, this.reason);

  /// What App Studio was doing, as a sentence fragment: "Moving the AppImage".
  final String step;
  final String reason;

  @override
  String toString() => '$step failed: $reason';
}

/// Adds the running AppImage to the app menu the way Gear Lever and
/// AppImageLauncher do, and removes what it added again.
///
/// Adding moves the AppImage to `~/AppImages/AppStudio-x86_64.AppImage`,
/// copies its icons into the user's icon theme folder and writes a desktop
/// entry named after the application id. Everything is under the user's home
/// directory, so nothing needs a password.
///
/// Every path comes from [environment], so tests point `HOME` at a
/// temporary folder; with [host] set to Linux they run on any machine.
/// Paths are built with this machine's own `package:path` context rather
/// than [host]'s: every one of them is read or written here, so on another
/// OS a test's temporary folder has to stay in that OS's form.
class DesktopIntegration {
  DesktopIntegration({
    Map<String, String>? environment,
    HostPlatform? host,
    Future<AppVersion?> Function()? runningVersion,
    String? executable,
  }) : environment = environment ?? Platform.environment,
       host = host ?? currentHost,
       _runningVersion = runningVersion ?? readRunningVersion,
       _executable = executable ?? Platform.resolvedExecutable;

  final Map<String, String> environment;

  /// Decides whether there is anything to offer: only Linux has an app menu
  /// this class writes to.
  final HostPlatform host;
  final Future<AppVersion?> Function() _runningVersion;

  /// This process's executable: inside `$APPDIR` when App Studio is the
  /// AppImage that set the variables.
  final String _executable;

  String? get _home {
    final home = environment['HOME'];
    return home == null || home.isEmpty ? null : home;
  }

  String? _variable(String name) {
    final value = environment[name];
    return value == null || value.isEmpty ? null : value;
  }

  /// `$XDG_DATA_HOME`, or `~/.local/share`. A relative value is invalid by
  /// the XDG base directory spec and is ignored.
  String? get _dataHome {
    final value = _variable('XDG_DATA_HOME');
    if (value != null && p.isAbsolute(value)) return value;
    final home = _home;
    return home == null ? null : p.join(home, '.local', 'share');
  }

  /// `$XDG_DATA_DIRS`, or the spec's default.
  List<String> get _dataDirs {
    final value = _variable('XDG_DATA_DIRS');
    final dirs = value == null
        ? const ['/usr/local/share', '/usr/share']
        : value.split(':');
    return [
      for (final dir in dirs)
        if (p.isAbsolute(dir)) dir,
    ];
  }

  /// The running AppImage's own path, as its runtime set it. After [add] it
  /// names where the file *was*.
  String? get _appImage => _variable('APPIMAGE');

  /// Where the running image is mounted.
  String? get _appDir => _variable('APPDIR');

  /// Where an added AppImage lives, or null without a home directory.
  ///
  /// `~/AppImages` is Gear Lever's folder, and nothing else watches it.
  /// AppImageLauncher's daemon adds whatever appears in `~/Applications`, and
  /// appimaged watches that folder too, so a file moved there could end up
  /// in the menu twice.
  String? get addedAppImagePath {
    final home = _home;
    return home == null ? null : p.join(home, 'AppImages', kAddedAppImageName);
  }

  String? get _entryPath {
    final dataHome = _dataHome;
    return dataHome == null
        ? null
        : p.join(dataHome, 'applications', '$kLinuxAppId.desktop');
  }

  /// The folder the AppImage is in now, for the question's wording: Add
  /// moves it from there. Null when it is in `~/AppImages` already, where
  /// Add at most renames it.
  Future<String?> currentFolder() async {
    final appImage = _appImage;
    final target = addedAppImagePath;
    // Gone: an earlier Add in this run moved it.
    if (appImage == null || !await File(appImage).exists()) return null;
    final folder = p.dirname(appImage);
    if (target != null && p.equals(folder, p.dirname(target))) return null;
    return folder;
  }

  /// Whether [add] has to copy the AppImage and leave the original where it
  /// is: App Studio may not take the file out of its folder (a root-owned
  /// `/opt`, a read-only file system, or a shared sticky folder such as
  /// `/tmp` with someone else's file). The question then says so rather
  /// than promising a move.
  ///
  /// Asked of the permissions, without writing anything: nothing outside
  /// App Studio's own folders is touched before the user answers. An
  /// immutable file (`chattr +i`) is not detected; Add still copies it, and
  /// only the wording is off.
  Future<bool> keepsOriginal() async {
    final folder = await currentFolder();
    final appImage = _appImage;
    if (folder == null || appImage == null) return false;
    try {
      // Taking a file out of a folder needs write and search permission on
      // the folder and, in a sticky one, owning the file or the folder, or
      // being root.
      final result = await Process.run('/bin/sh', [
        '-c',
        r'[ -w "$1" ] && [ -x "$1" ] && '
            r'{ [ ! -k "$1" ] || [ -O "$1" ] || [ -O "$2" ] || '
            r'[ "$(id -u)" = 0 ]; }',
        'sh',
        folder,
        appImage,
      ]);
      return result.exitCode != 0;
    } on ProcessException {
      // No shell to ask: say it moves, as before.
      return false;
    }
  }

  /// Whether [add] would replace another file at [addedAppImagePath]: a copy
  /// left there after Remove, or after its entry was deleted by hand. It may
  /// be a newer build, so the question says so.
  Future<bool> replacesAnotherFile() async {
    final appImage = _appImage;
    final target = addedAppImagePath;
    if (appImage == null || target == null || alreadyInPlace) return false;
    // After this copy's own Add, `$APPIMAGE` names where it was and the file
    // at the target is this one.
    return await File(appImage).exists() && await File(target).exists();
  }

  /// Whether the AppImage is already where [add] would move it.
  bool get alreadyInPlace {
    final appImage = _appImage;
    final target = addedAppImagePath;
    return appImage != null && target != null && p.equals(appImage, target);
  }

  Future<DesktopIntegrationStatus> status() async {
    if (!host.isLinux || runningAppImage(environment, _executable) == null) {
      return DesktopIntegrationStatus.unavailable;
    }
    final entryPath = _entryPath;
    if (entryPath == null) return DesktopIntegrationStatus.unavailable;
    // A portable AppImage: the runtime pointed HOME at `<AppImage>.home`, so
    // an entry written under it would never reach the desktop.
    if (await Directory('${_appImage!}.home').exists()) {
      return DesktopIntegrationStatus.unavailable;
    }

    final own = await _readEntry(entryPath);
    if (own != null && _isOurs(own) && await _targetExists(own)) {
      return DesktopIntegrationStatus.addedByAppStudio;
    }
    // Whether another tool is installed does not matter, only whether it
    // added App Studio: an entry is what puts it in the menu.
    if (await _otherEntryExists(ownEntry: entryPath)) {
      return DesktopIntegrationStatus.managedByOther;
    }
    return DesktopIntegrationStatus.notAdded;
  }

  /// An entry of ours whose AppImage is gone (the user deleted the file) adds
  /// nothing to the menu — launchers hide it by its `TryExec` — so it does not
  /// count, and [add] writes over it.
  Future<bool> _targetExists(Map<String, String> entry) async {
    final tryExec = entry['TryExec'];
    return tryExec != null && await File(tryExec).exists();
  }

  bool _isOurs(Map<String, String> entry) =>
      entry[kAddedByKey] == kAddedByValue;

  /// Any other entry for App Studio, in the user's folder or the system's:
  /// named after the application id, or naming it as its window class.
  /// AppImageLauncher and appimaged name their entries after a hash of the
  /// file, but keep the AppImage's own `StartupWMClass`.
  Future<bool> _otherEntryExists({required String ownEntry}) async {
    final dataHome = _dataHome;
    final folders = [
      if (dataHome != null) p.join(dataHome, 'applications'),
      for (final dir in _dataDirs) p.join(dir, 'applications'),
    ];
    for (final folder in folders) {
      final dir = Directory(folder);
      if (!await dir.exists()) continue;
      try {
        // Recursive: a desktop file id may sit in a sub-folder (`kde4/…`).
        // A sub-folder that cannot be read is skipped, not the rest of the
        // folder with it.
        final files = dir
            .list(recursive: true, followLinks: true)
            .handleError(
              (Object e) => debugPrint('Skipping in $folder: $e'),
              test: (e) => e is FileSystemException,
            );
        await for (final file in files) {
          if (file is! File || !file.path.endsWith('.desktop')) continue;
          final entry = await _readEntry(file.path);
          if (entry == null) continue;
          final named = p.basename(file.path) == '$kLinuxAppId.desktop';
          final matches = entry['StartupWMClass'] == kLinuxAppId;
          if (!named && !matches) continue;
          if (p.equals(file.path, ownEntry) && _isOurs(entry)) continue;
          // An entry whose program is gone is hidden by launchers: a tool's
          // leftover after the user deleted the AppImage. (appimaged's
          // `TryExec` names appimaged itself, which stays.)
          final tryExec = entry['TryExec'];
          if (tryExec != null &&
              p.isAbsolute(tryExec) &&
              !await File(tryExec).exists()) {
            continue;
          }
          return true;
        }
      } on FileSystemException {
        continue;
      }
    }
    return false;
  }

  /// Adds the running AppImage to the app menu. Throws
  /// [DesktopIntegrationException] naming the step that failed; the steps
  /// before it are undone, apart from the move, since the AppImage runs on
  /// from its new place either way.
  Future<void> add() async {
    final appImage = _appImage;
    final appDir = _appDir;
    final target = addedAppImagePath;
    final dataHome = _dataHome;
    final entryPath = _entryPath;
    if (appImage == null ||
        appDir == null ||
        target == null ||
        dataHome == null ||
        entryPath == null) {
      throw const DesktopIntegrationException(
        'Adding App Studio',
        'App Studio is not running as an AppImage.',
      );
    }

    await _step('Moving the AppImage to ~/AppImages', () async {
      if (alreadyInPlace) return;
      if (await File(appImage).exists()) {
        await _move(appImage, target);
      } else if (!await File(target).exists()) {
        throw FileSystemException('The AppImage is gone', appImage);
      }
      // Otherwise an earlier try moved it, and `$APPIMAGE` still names the
      // place it was.
    });

    final written = <String>[];
    try {
      await _step('Copying the icons', () async {
        final source = Directory(
          p.join(appDir, 'usr', 'share', 'icons', 'hicolor'),
        );
        final destination = p.join(dataHome, 'icons', 'hicolor');
        await for (final file in source.list(recursive: true)) {
          if (file is! File) continue;
          final to = p.join(
            destination,
            p.relative(file.path, from: source.path),
          );
          await Directory(p.dirname(to)).create(recursive: true);
          // Only what this Add created is undone. An icon already there
          // (a Replace) is the one the existing entry shows.
          final existed = await File(to).exists();
          await file.copy(to);
          if (!existed) written.add(to);
        }
      });
      await _step('Writing the app menu entry', () async {
        final source = await _sourceEntry(appDir);
        final entry = desktopEntryFor(
          source,
          appImagePath: target,
          version: await _runningVersion(),
        );
        await Directory(p.dirname(entryPath)).create(recursive: true);
        final temporary = File('$entryPath.$pid.part');
        await temporary.writeAsString(entry, flush: true);
        written.add(temporary.path);
        final existed = await File(entryPath).exists();
        await temporary.rename(entryPath);
        written.remove(temporary.path);
        if (!existed) written.add(entryPath);
      });
    } on DesktopIntegrationException catch (e) {
      for (final path in written.reversed) {
        try {
          await File(path).delete();
        } on FileSystemException {
          // Already gone, or never written.
        }
      }
      if (!written.contains(entryPath)) {
        await _forgetRecordedVersion(entryPath);
      }
      // The move is not undone, so say where the file went.
      throw DesktopIntegrationException(
        e.step,
        alreadyInPlace
            ? e.reason
            : '${e.reason} The AppImage is now at '
                  '~/AppImages/$kAddedAppImageName.',
      );
    }
    await _refreshIconCache(dataHome);
  }

  /// After a failed Add, an entry of ours that was there before stays, so
  /// the menu keeps working. Its `TryExec` names the fixed path, which may
  /// hold another build by now, so the version it records is dropped:
  /// compared with the next download, a wrong one could offer to replace a
  /// newer copy with an older one. Without it, no copy is compared until the
  /// next Add writes the entry again. Best effort, like the cleanup before.
  Future<void> _forgetRecordedVersion(String entryPath) =>
      _setRecordedVersion(entryPath, null);

  /// After an update replaced [appImagePath] in place: App Studio's entry,
  /// when it names that file, records [version] from now on, so another
  /// copy is compared with the build that is really there. Best effort.
  Future<void> recordUpdatedVersion(
    String appImagePath,
    AppVersion version,
  ) async {
    final entryPath = _entryPath;
    if (entryPath == null) return;
    final entry = await _readEntry(entryPath);
    if (entry == null || !_isOurs(entry)) return;
    final tryExec = entry['TryExec'];
    if (tryExec == null || !p.equals(tryExec, appImagePath)) return;
    await _setRecordedVersion(entryPath, version);
  }

  /// The version App Studio's entry records for [appImagePath], or null
  /// when there is no entry of App Studio's naming that file, or no version.
  Future<AppVersion?> recordedVersionOf(String appImagePath) async {
    final entryPath = _entryPath;
    if (entryPath == null) return null;
    final entry = await _readEntry(entryPath);
    if (entry == null || !_isOurs(entry)) return null;
    final tryExec = entry['TryExec'];
    if (tryExec == null || !p.equals(tryExec, appImagePath)) return null;
    final version = entry[kAddedVersionKey];
    final build = int.tryParse(entry[kAddedBuildKey] ?? '');
    if (version == null || build == null) return null;
    return AppVersion(version, build);
  }

  /// Rewrites the version keys of App Studio's entry at [entryPath]: drops
  /// them, then writes [version] after the marker when there is one. Every
  /// other line stays as it was.
  Future<void> _setRecordedVersion(
    String entryPath,
    AppVersion? version,
  ) async {
    final file = File(entryPath);
    if (!await file.exists()) return;
    try {
      final contents = await file.readAsString();
      final entry = parseDesktopEntry(contents);
      if (!_isOurs(entry)) return;
      final kept = <String>[];
      var inGroup = false;
      for (final line in contents.split('\n')) {
        if (line.startsWith('[')) {
          inGroup = line.trimRight() == '[Desktop Entry]';
        } else if (inGroup) {
          final key = line.split('=').first.trim();
          if (key == kAddedVersionKey || key == kAddedBuildKey) continue;
          if (key == kAddedByKey && version != null) {
            kept
              ..add(line)
              ..add('$kAddedVersionKey=${_escapeString(version.version)}')
              ..add('$kAddedBuildKey=${version.build}');
            continue;
          }
        }
        kept.add(line);
      }
      final updated = kept.join('\n');
      if (updated == contents) return;
      final temporary = File('$entryPath.$pid.part');
      await temporary.writeAsString(updated, flush: true);
      await temporary.rename(entryPath);
    } on FileSystemException catch (e) {
      debugPrint('Could not record the version in $entryPath: $e');
    } on FormatException catch (e) {
      debugPrint('Could not record the version in $entryPath: $e');
    }
  }

  /// Tells the desktop the icons changed, as `xdg-icon-resource` does.
  /// GTK rescans a theme only when the theme folder's own modification time
  /// moves, not its size folders', and judges an icon cache stale the same
  /// way: icons copied into folders an earlier Add left behind stayed
  /// generic until the next login. So the folder's time is moved first, by
  /// adding a file and taking it away again (xdg's `.xdg-icon-resource-dummy`
  /// does the same), and then an icon cache, where there is one, is
  /// rebuilt. Should the rebuild fail, the moved time still marks the old
  /// cache stale, and icons are looked up on disk. Best effort; a missed
  /// refresh only costs the icon until the next one.
  Future<void> _refreshIconCache(String dataHome) async {
    final hicolor = p.join(dataHome, 'icons', 'hicolor');
    // Nothing to refresh, and no folder to create, where none is.
    if (!await Directory(hicolor).exists()) return;
    try {
      final marker = File(p.join(hicolor, '.appstudio-$pid'));
      await marker.create();
      await marker.delete();
    } on FileSystemException catch (e) {
      debugPrint('Could not refresh the icons in $hicolor: $e');
    }
    if (!await File(p.join(hicolor, 'icon-theme.cache')).exists()) return;
    try {
      await Process.run('gtk-update-icon-cache', ['-f', '-t', hicolor]);
    } on ProcessException catch (e) {
      debugPrint('gtk-update-icon-cache failed: $e');
    }
  }

  /// Removes the desktop entry App Studio wrote and the icons it copied —
  /// only when the entry carries [kAddedByKey], so an entry another tool
  /// wrote under the same name stays. The AppImage itself stays. Throws when
  /// there is no entry of App Studio's to remove: another tool may have
  /// rewritten it since the menu last looked.
  Future<void> remove() async {
    const step = 'Removing the app menu entry';
    final entryPath = _entryPath;
    final dataHome = _dataHome;
    if (entryPath == null || dataHome == null) {
      throw const DesktopIntegrationException(step, 'There is no home folder.');
    }
    final entry = await _readEntry(entryPath);
    if (entry == null) {
      throw const DesktopIntegrationException(
        step,
        'App Studio is not in your app menu.',
      );
    }
    if (!_isOurs(entry)) {
      throw const DesktopIntegrationException(
        step,
        'Another app manages App Studio\'s entry in your app menu now.',
      );
    }

    await _step(step, () async {
      await File(entryPath).delete();
    });
    await _step('Removing the icons', () async {
      final hicolor = Directory(p.join(dataHome, 'icons', 'hicolor'));
      if (!await hicolor.exists()) return;
      await for (final size in hicolor.list()) {
        if (size is! Directory) continue;
        final icon = File(p.join(size.path, 'apps', '$kLinuxAppId.png'));
        if (await icon.exists()) await icon.delete();
      }
    });
    await _refreshIconCache(dataHome);
  }

  /// The running copy and the one in the app menu, when they are different
  /// files and App Studio added the latter. Null otherwise, and when either
  /// version is unknown: then there is nothing reliable to say.
  Future<OtherCopy?> otherCopy() async {
    if (await status() != DesktopIntegrationStatus.addedByAppStudio) {
      return null;
    }
    final appImage = _appImage;
    final entryPath = _entryPath;
    if (appImage == null || entryPath == null || alreadyInPlace) return null;
    // After this copy's own Add, `$APPIMAGE` names where it was.
    if (!await File(appImage).exists()) return null;
    final entry = await _readEntry(entryPath);
    final addedVersion = entry?[kAddedVersionKey];
    final addedBuild = int.tryParse(entry?[kAddedBuildKey] ?? '');
    final running = await _runningVersion();
    if (addedVersion == null || addedBuild == null || running == null) {
      return null;
    }
    return OtherCopy(
      running: running,
      added: AppVersion(addedVersion, addedBuild),
    );
  }

  /// Starts the copy in the app menu once this process has ended (see
  /// [startAfterExit]); the caller quits right after. [afterPid] is the
  /// process to wait for; tests hand it one of their own.
  Future<void> openAddedCopyAfterExit({
    @visibleForTesting int? afterPid,
  }) async {
    final target = addedAppImagePath;
    if (target == null || !await File(target).exists()) {
      throw FileSystemException('The AppImage is gone', target);
    }
    await startAfterExit(target, afterPid: afterPid);
  }

  /// A rename where it can be; across file systems a copy to a temporary
  /// name beside [to], a rename onto it, then the original goes. A file
  /// already at [to] is only ever replaced by a rename, so it is never half
  /// written. An original that cannot be deleted stays: the copy works.
  Future<void> _move(String from, String to) async {
    await Directory(p.dirname(to)).create(recursive: true);
    try {
      await File(from).rename(to);
      return;
    } on FileSystemException {
      // Another file system (EXDEV), or a folder the file cannot be taken out
      // of (EACCES on a root-owned one): a copy still works. A problem with
      // the target shows up again in the copy, with its own reason.
    }
    final temporary = '$to.$pid.part';
    try {
      await File(from).copy(temporary);
      await _makeExecutable(temporary);
      await File(temporary).rename(to);
    } catch (_) {
      try {
        await File(temporary).delete();
      } on FileSystemException {
        // Never written.
      }
      rethrow;
    }
    try {
      await File(from).delete();
    } on FileSystemException catch (e) {
      debugPrint('Could not delete $from after copying it: $e');
    }
  }

  /// `File.copy` keeps the mode on Linux today, but an AppImage that is not
  /// executable does not start at all, so it is set rather than relied on.
  /// Dart has no chmod.
  Future<void> _makeExecutable(String path) async {
    final result = await Process.run('chmod', ['755', path]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'chmod failed: ${(result.stderr as String).trim()}',
        path,
      );
    }
  }

  Future<String> _sourceEntry(String appDir) async {
    for (final path in [
      p.join(appDir, 'usr', 'share', 'applications', '$kLinuxAppId.desktop'),
      p.join(appDir, '$kLinuxAppId.desktop'),
    ]) {
      final file = File(path);
      if (await file.exists()) return file.readAsString();
    }
    throw FileSystemException('The AppImage carries no desktop entry', appDir);
  }

  Future<void> _step(String step, Future<void> Function() run) async {
    try {
      await run();
    } on DesktopIntegrationException {
      rethrow;
    } on FileSystemException catch (e) {
      final reason = e.osError?.message ?? e.message;
      throw DesktopIntegrationException(
        step,
        e.path == null ? reason : '$reason (${e.path})',
      );
    } on ProcessException catch (e) {
      throw DesktopIntegrationException(step, e.message);
    } on FormatException catch (e) {
      throw DesktopIntegrationException(step, e.message);
    }
  }

  /// The `[Desktop Entry]` group's keys, or null when there is no readable
  /// file there.
  Future<Map<String, String>?> _readEntry(String path) async {
    try {
      return parseDesktopEntry(await File(path).readAsString());
    } on FileSystemException {
      return null;
    } on FormatException {
      // Not UTF-8: not an entry anyone could have meant for App Studio.
      return null;
    }
  }
}

/// The keys of [contents]' `[Desktop Entry]` group. Localised keys
/// (`Name[de]`) are kept under their full name; values are returned as
/// written, unescaped only for the `\s`, `\n`, `\t`, `\r` and `\\` escapes.
@visibleForTesting
Map<String, String> parseDesktopEntry(String contents) {
  final keys = <String, String>{};
  var inGroup = false;
  for (final raw in contents.split('\n')) {
    final line = raw.trimRight();
    if (line.startsWith('[')) {
      inGroup = line == '[Desktop Entry]';
      continue;
    }
    if (!inGroup || line.startsWith('#')) continue;
    final equals = line.indexOf('=');
    if (equals <= 0) continue;
    keys[line.substring(0, equals).trim()] = _unescape(
      line.substring(equals + 1).trimLeft(),
    );
  }
  return keys;
}

String _unescape(String value) => value.replaceAllMapped(
  RegExp(r'\\(.)'),
  (m) => switch (m[1]) {
    's' => ' ',
    'n' => '\n',
    't' => '\t',
    'r' => '\r',
    '\\' => r'\',
    _ => m[0]!,
  },
);

/// [source] — the AppImage's own entry — pointed at [appImagePath]: `Exec`
/// and `TryExec` replaced, the marker added, and with it the [version] of the
/// file being added. Every other line, the other
/// groups included, is kept as it was.
@visibleForTesting
String desktopEntryFor(
  String source, {
  required String appImagePath,
  AppVersion? version,
}) {
  if (appImagePath.contains(RegExp(r'[\n\r]'))) {
    throw FileSystemException(
      'A path with a line break cannot go in a desktop entry',
      appImagePath,
    );
  }
  final out = <String>[];
  var inGroup = false;
  var wroteKeys = false;
  void writeKeys() {
    if (wroteKeys) return;
    out
      ..add('Exec=${_execArgument(appImagePath)}')
      ..add('TryExec=${_escapeString(appImagePath)}')
      ..add('$kAddedByKey=$kAddedByValue');
    if (version != null) {
      out
        ..add('$kAddedVersionKey=${_escapeString(version.version)}')
        ..add('$kAddedBuildKey=${version.build}');
    }
    wroteKeys = true;
  }

  final lines = source.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  for (final line in lines) {
    if (line.startsWith('[')) {
      if (inGroup) writeKeys();
      inGroup = line.trimRight() == '[Desktop Entry]';
      out.add(line);
      continue;
    }
    if (inGroup) {
      final key = line.split('=').first.trim();
      if (const {
        'Exec',
        'TryExec',
        kAddedByKey,
        kAddedVersionKey,
        kAddedBuildKey,
      }.contains(key)) {
        continue;
      }
    }
    out.add(line);
  }
  if (inGroup) writeKeys();
  if (!wroteKeys) {
    throw const FormatException('The AppImage entry has no [Desktop Entry]');
  }
  return '${out.join('\n')}\n';
}

/// A string value, escaped as the Desktop Entry spec says: a backslash, a
/// newline, a tab and a carriage return each become two characters, so no
/// value can start a line of its own.
String _escapeString(String value) => value
    .replaceAll(r'\', r'\\')
    .replaceAll('\n', r'\n')
    .replaceAll('\t', r'\t')
    .replaceAll('\r', r'\r');

/// One `Exec` argument, quoted as the Desktop Entry spec says: inside double
/// quotes, `"`, `` ` ``, `$` and `\` take a backslash, and `%` is doubled.
/// The string escaping applies on top, which is why a backslash ends up as
/// four.
String _execArgument(String value) {
  final quoted = value
      .replaceAllMapped(RegExp(r'["`$\\]'), (m) => '\\${m[0]}')
      .replaceAll('%', '%%');
  return _escapeString('"$quoted"');
}

/// [DesktopIntegration]'s state for the UI: the menu strip listens to it, and
/// the question on first start reads it.
class DesktopIntegrationController extends ChangeNotifier {
  DesktopIntegrationController({DesktopIntegration? integration})
    : integration = integration ?? DesktopIntegration();

  final DesktopIntegration integration;

  DesktopIntegrationStatus _status = DesktopIntegrationStatus.unavailable;
  DesktopIntegrationStatus get status => _status;

  bool _disposed = false;

  /// Reads the state from disk. Never throws: anything unreadable counts as
  /// "nothing to offer".
  Future<void> refresh() async {
    DesktopIntegrationStatus status;
    try {
      status = await integration.status();
    } catch (e) {
      debugPrint('desktop integration status failed: $e');
      status = DesktopIntegrationStatus.unavailable;
    }
    if (_disposed || status == _status) return;
    _status = status;
    notifyListeners();
  }

  /// [DesktopIntegration.add], then a fresh [status]. Throws what `add`
  /// throws, after refreshing, since a failed step may still have moved the
  /// file.
  Future<void> add() async {
    try {
      await integration.add();
    } finally {
      await refresh();
    }
  }

  Future<void> remove() async {
    try {
      await integration.remove();
    } finally {
      await refresh();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
