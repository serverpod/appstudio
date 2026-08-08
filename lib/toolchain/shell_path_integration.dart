/// Opt-in `PATH` integration for the user's own terminal.
///
/// App Studio never needs this — it sets `PATH` for every process it spawns.
/// It exists so an external editor or AI agent can find the tools.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

export 'shell_path_state.dart';

import 'shell_path_state.dart';

const kShellBlockStart = '# >>> App Studio >>>';
const kShellBlockEnd = '# <<< App Studio <<<';

/// A managed block found in a shell rc file.
class ShellBlock {
  const ShellBlock({
    required this.startLine,
    required this.endLine,
    required this.body,
    required this.edited,
  });

  final int startLine;
  final int endLine;
  final String body;

  /// True when the body no longer matches its recorded checksum, i.e. someone
  /// edited inside the fence. Never overwrite one of these silently.
  final bool edited;
}

/// Locates the managed block, or null when there is none.
ShellBlock? findShellBlock(String rc) {
  final lines = const LineSplitter().convert(rc);
  final start = lines.indexOf(kShellBlockStart);
  if (start < 0) return null;
  final end = lines.indexOf(kShellBlockEnd, start + 1);
  if (end < 0) return null;

  final body = lines.sublist(start + 1, end).join('\n');
  return ShellBlock(
    startLine: start,
    endLine: end,
    body: body,
    edited: !_checksumMatches(body),
  );
}

/// The block we would write for [binDir].
String renderShellBlock(String binDir) {
  final export = 'export PATH="$binDir:\$PATH"';
  final body = [
    '# Managed by App Studio — do not edit inside this block.',
    export,
  ].join('\n');
  return [
    kShellBlockStart,
    '# checksum: ${_checksum(body)}',
    body,
    kShellBlockEnd,
  ].join('\n');
}

/// Inserts or replaces the block, leaving exactly one.
///
/// Appends at the end after a single blank line. Prepending is tempting so our
/// PATH wins, but it breaks `.zshrc` files whose first lines are powerlevel10k
/// instant-prompt guards — and ordering within the session is already decided
/// by the `PATH=…:$PATH` prefix.
String applyShellBlock(String rc, String block) {
  final stripped = removeShellBlock(rc);
  if (stripped.trim().isEmpty) return '$block\n';
  final base = stripped.endsWith('\n')
      ? stripped.substring(0, stripped.length - 1)
      : stripped;
  return '$base\n\n$block\n';
}

/// Removes every managed block, tidying the blank lines they leave behind.
String removeShellBlock(String rc) {
  if (!rc.contains(kShellBlockStart)) return rc;

  final endsWithNewline = rc.endsWith('\n');
  final lines = const LineSplitter().convert(rc);
  final kept = <String>[];

  var index = 0;
  while (index < lines.length) {
    if (lines[index] == kShellBlockStart) {
      final end = lines.indexOf(kShellBlockEnd, index + 1);
      if (end >= 0) {
        // Also drop the blank line we inserted before the block.
        if (kept.isNotEmpty && kept.last.trim().isEmpty) kept.removeLast();
        index = end + 1;
        continue;
      }
    }
    kept.add(lines[index]);
    index++;
  }

  // A file that was only ever our block becomes empty, not a stray newline.
  while (kept.isNotEmpty && kept.last.trim().isEmpty) {
    kept.removeLast();
  }
  if (kept.isEmpty) return '';
  return endsWithNewline ? '${kept.join('\n')}\n' : kept.join('\n');
}

String _checksum(String body) =>
    sha256.convert(utf8.encode(body)).toString().substring(0, 12);

bool _checksumMatches(String body) {
  final lines = const LineSplitter().convert(body);
  final recorded = lines
      .where((l) => l.startsWith('# checksum: '))
      .map((l) => l.substring('# checksum: '.length).trim())
      .firstOrNull;
  if (recorded == null) return false;
  final withoutChecksum =
      lines.where((l) => !l.startsWith('# checksum: ')).join('\n');
  return _checksum(withoutChecksum) == recorded;
}

/// Which rc file to edit, based on `$SHELL`.
///
/// zsh gets `.zshrc` rather than `.zprofile`: `.zprofile` is login-only, which
/// Terminal.app satisfies but the integrated terminals in VS Code and
/// JetBrains do not.
class ShellTarget {
  const ShellTarget({required this.shell, required this.rcPath});

  final String shell;

  /// Null when we do not know how to edit this shell's config.
  final String? rcPath;

  bool get isSupported => rcPath != null;

  static ShellTarget resolve({String? shellOverride, String? homeOverride}) {
    final shellPath =
        shellOverride ?? Platform.environment['SHELL'] ?? '/bin/zsh';
    final shell = p.basename(shellPath);
    final home = homeOverride ?? Platform.environment['HOME'];
    if (home == null || home.isEmpty) {
      return ShellTarget(shell: shell, rcPath: null);
    }

    return switch (shell) {
      'zsh' => ShellTarget(shell: shell, rcPath: p.join(home, '.zshrc')),
      // macOS bash login shells read .bash_profile; .bashrc is not sourced.
      'bash' => ShellTarget(
          shell: shell,
          rcPath: File(p.join(home, '.bash_profile')).existsSync()
              ? p.join(home, '.bash_profile')
              : p.join(home, '.profile'),
        ),
      // fish uses a different syntax; show the line instead of guessing.
      _ => ShellTarget(shell: shell, rcPath: null),
    };
  }
}


/// Reads and writes the managed block on disk.
class ShellPathIntegration {
  const ShellPathIntegration({required this.binDir, required this.target});

  final String binDir;
  final ShellTarget target;

  /// The line a user of an unsupported shell can add by hand.
  String get exportLine => 'export PATH="$binDir:\$PATH"';

  Future<ShellPathState> state() async {
    final path = target.rcPath;
    if (path == null) return ShellPathState.unsupported;
    final file = File(path);
    if (!await file.exists()) return ShellPathState.absent;
    final block = findShellBlock(await file.readAsString());
    if (block == null) return ShellPathState.absent;
    return block.edited ? ShellPathState.edited : ShellPathState.present;
  }

  /// Adds or refreshes the block. Returns the file that changed.
  ///
  /// Writes via a temp file and rename: a crash mid-write must never leave a
  /// truncated `.zshrc`.
  Future<String> enable({bool force = false}) async {
    final path = target.rcPath;
    if (path == null) {
      throw const ShellPathException(
        'App Studio does not know how to edit this shell\'s configuration.',
      );
    }
    final file = File(path);
    final existing = await file.exists() ? await file.readAsString() : '';

    final block = findShellBlock(existing);
    if (block != null && block.edited && !force) {
      throw const ShellPathException(
        'Your shell config was edited inside the App Studio block.',
        wasEdited: true,
      );
    }
    if (block != null && block.edited && force) {
      await _backup(file, existing);
    }

    await _writeAtomically(file, applyShellBlock(existing, renderShellBlock(binDir)));
    return path;
  }

  /// Removes the block. Backs up first if it was hand-edited.
  Future<String?> disable() async {
    final path = target.rcPath;
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;

    final existing = await file.readAsString();
    final block = findShellBlock(existing);
    if (block == null) return null;
    if (block.edited) await _backup(file, existing);

    await _writeAtomically(file, removeShellBlock(existing));
    return path;
  }

  Future<void> _backup(File file, String contents) async {
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    await File('${file.path}.appstudio-backup-$stamp').writeAsString(contents);
  }

  Future<void> _writeAtomically(File file, String contents) async {
    final temp = File('${file.path}.appstudio-tmp');
    await temp.writeAsString(contents, flush: true);
    await temp.rename(file.path);
  }
}

class ShellPathException implements Exception {
  const ShellPathException(this.message, {this.wasEdited = false});

  final String message;
  final bool wasEdited;

  @override
  String toString() => message;
}
