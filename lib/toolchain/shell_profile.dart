/// The user's shell config, and the `PATH` lines App Studio adds to it.
///
/// The lines are exactly the ones the official instructions give — Flutter's
/// for its SDK, `dart install`'s for its bin directory — written to the file
/// Flutter's macOS instructions name. Each one is recorded as written, so
/// uninstall removes that exact line and nothing else.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The rc file to add `PATH` lines to, from `$SHELL`.
///
/// zsh gets `~/.zprofile` because that is what Flutter's macOS instructions
/// say. bash gets `~/.bash_profile`, which macOS login shells read. Anything
/// else (fish, nu) has its own syntax, so the lines are shown for the user to
/// add rather than guessed at.
class ShellProfile {
  const ShellProfile({required this.shell, required this.path});

  final String shell;

  /// Null when we do not know how to edit this shell's config.
  final String? path;

  bool get isSupported => path != null;

  static ShellProfile resolve({required String home, String? shellOverride}) {
    final shellPath =
        shellOverride ?? Platform.environment['SHELL'] ?? '/bin/zsh';
    final shell = p.basename(shellPath);
    return switch (shell) {
      'zsh' => ShellProfile(shell: shell, path: p.join(home, '.zprofile')),
      'bash' => ShellProfile(shell: shell, path: p.join(home, '.bash_profile')),
      _ => ShellProfile(shell: shell, path: null),
    };
  }
}

/// Flutter's line: `export PATH="$HOME/develop/flutter/bin:$PATH"`.
String flutterPathLine(String binDir, {required String home}) =>
    'export PATH="${_homeRelative(binDir, home)}:\$PATH"';

/// The line `dart install` asks for:
/// `export PATH="$PATH":"$HOME/Library/Application Support/Dart/install/bin"`.
String dartInstallPathLine(String binDir, {required String home}) =>
    'export PATH="\$PATH":"${_homeRelative(binDir, home)}"';

/// `$HOME/…` for a directory under [home], as both sets of instructions write
/// it, so the line still reads right if the home directory is ever renamed.
String _homeRelative(String dir, String home) =>
    p.isWithin(home, dir) ? '\$HOME/${p.relative(dir, from: home)}' : dir;

// ---------------------------------------------------------------------------
// Pure edits
// ---------------------------------------------------------------------------

/// [contents] with [line] at the end, or unchanged when it is already there.
String withLine(String contents, String line) {
  if (const LineSplitter().convert(contents).contains(line)) return contents;
  if (contents.isEmpty) return '$line\n';
  final separator = contents.endsWith('\n') ? '' : '\n';
  return '$contents$separator$line\n';
}

/// [contents] without any line equal to [line]. Nothing else is touched —
/// not whitespace, not a line that merely resembles it.
String withoutLine(String contents, String line) {
  final lines = const LineSplitter().convert(contents);
  if (!lines.contains(line)) return contents;
  final kept = [for (final l in lines) if (l != line) l];
  if (kept.isEmpty) return '';
  return contents.endsWith('\n') ? '${kept.join('\n')}\n' : kept.join('\n');
}

// ---------------------------------------------------------------------------
// The block earlier builds wrote
// ---------------------------------------------------------------------------

const kLegacyShellBlockStart = '# >>> App Studio >>>';
const kLegacyShellBlockEnd = '# <<< App Studio <<<';

bool hasLegacyShellBlock(String contents) =>
    const LineSplitter().convert(contents).contains(kLegacyShellBlockStart);

/// Removes every fenced block an earlier build wrote, and the blank line it
/// put before each one. The block pointed at wrapper scripts in Application
/// Support, which are gone.
String withoutLegacyShellBlock(String contents) {
  if (!hasLegacyShellBlock(contents)) return contents;

  final endsWithNewline = contents.endsWith('\n');
  final lines = const LineSplitter().convert(contents);
  final kept = <String>[];

  var index = 0;
  while (index < lines.length) {
    if (lines[index] == kLegacyShellBlockStart) {
      final end = lines.indexOf(kLegacyShellBlockEnd, index + 1);
      if (end >= 0) {
        if (kept.isNotEmpty && kept.last.trim().isEmpty) kept.removeLast();
        index = end + 1;
        continue;
      }
    }
    kept.add(lines[index]);
    index++;
  }

  while (kept.isNotEmpty && kept.last.trim().isEmpty) {
    kept.removeLast();
  }
  if (kept.isEmpty) return '';
  return endsWithNewline ? '${kept.join('\n')}\n' : kept.join('\n');
}

// ---------------------------------------------------------------------------
// On disk
// ---------------------------------------------------------------------------

/// Appends [line] to [path]. Returns false when it was already there, in which
/// case it is not ours to record.
Future<bool> appendShellLine(String path, String line) =>
    _edit(path, (contents) => withLine(contents, line), create: true);

/// Removes [line] from [path]. Returns false when it was not there.
Future<bool> removeShellLine(String path, String line) =>
    _edit(path, (contents) => withoutLine(contents, line));

Future<bool> removeLegacyShellBlock(String path) =>
    _edit(path, withoutLegacyShellBlock);

Future<bool> fileHasLegacyShellBlock(String path) async {
  try {
    final file = File(path);
    if (!await file.exists()) return false;
    return hasLegacyShellBlock(await file.readAsString());
  } catch (_) {
    return false;
  }
}

/// Reads, transforms and — only if something changed — writes [path].
///
/// Written through a temp file and a rename, so a crash can never leave a
/// truncated rc file. The rename goes to the *resolved* path: dotfile managers
/// symlink these files, and renaming over the link would replace it with a
/// plain file and quietly detach the user's config from their repo.
Future<bool> _edit(
  String path,
  String Function(String contents) transform, {
  bool create = false,
}) async {
  var file = File(path);
  final exists = await file.exists();
  if (!exists && !create) return false;
  if (exists) file = File(await file.resolveSymbolicLinks());

  final before = exists ? await file.readAsString() : '';
  final after = transform(before);
  if (after == before) return false;

  final temp = File('${file.path}.appstudio-tmp');
  await temp.writeAsString(after, flush: true);
  await temp.rename(file.path);
  return true;
}
