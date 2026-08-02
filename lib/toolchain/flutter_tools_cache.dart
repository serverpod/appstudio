import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Makes a freshly-installed Flutter SDK usable without rebuilding
/// `flutter_tools`.
///
/// Without this, the first `flutter` invocation on the target Mac recompiles
/// the tool and fails with `'File' isn't a type`, because `package:file` in the
/// shipped `.dart_tool` points at the *build* machine's pub cache.
///
/// Dart port of `tool/ensure_flutter_tools_cache.sh` (kept in sync; the shell
/// version still runs at pack time). Deliberately git-free: the revision comes
/// from `bin/cache/flutter.version.json`, which is byte-identical to
/// `git rev-parse HEAD`, so Flutter can be installed before git is.
Future<void> ensureFlutterToolsCache(String flutterRoot) async {
  final snapshot = File(
    p.join(flutterRoot, 'bin', 'cache', 'flutter_tools.snapshot'),
  );
  if (!await snapshot.exists()) {
    throw FlutterToolsCacheException(
      'The Flutter SDK is missing bin/cache/flutter_tools.snapshot.',
    );
  }

  final revision = await _readRevision(flutterRoot);
  if (revision == null) {
    throw FlutterToolsCacheException(
      'Could not determine the Flutter revision from '
      'bin/cache/flutter.version.json.',
    );
  }

  // Matches shared.sh's compilekey when FLUTTER_TOOL_ARGS is unset.
  await File(p.join(flutterRoot, 'bin', 'cache', 'flutter_tools.stamp'))
      .writeAsString('$revision:\n');

  final toolsDir = p.join(flutterRoot, 'packages', 'flutter_tools');

  // shared.sh rebuilds when pubspec.yaml is newer than pubspec.lock, and tar
  // does not guarantee their relative order.
  final lock = File(p.join(toolsDir, 'pubspec.lock'));
  if (await lock.exists()) {
    await lock.setLastModified(DateTime.now());
  }

  // Holds absolute paths into the machine that packed the archive.
  final dartTool = Directory(p.join(toolsDir, '.dart_tool'));
  if (await dartTool.exists()) {
    await dartTool.delete(recursive: true);
  }
}

Future<String?> _readRevision(String flutterRoot) async {
  final versionFile = File(
    p.join(flutterRoot, 'bin', 'cache', 'flutter.version.json'),
  );
  if (await versionFile.exists()) {
    try {
      final decoded = jsonDecode(await versionFile.readAsString());
      if (decoded is Map) {
        final revision = decoded['frameworkRevision'] as String?;
        if (revision != null && revision.isNotEmpty) return revision;
      }
    } catch (_) {
      // Fall through to the git checkout below.
    }
  }

  // Pre-3.4x SDKs have no version JSON; read the ref the checkout points at.
  final head = File(p.join(flutterRoot, '.git', 'HEAD'));
  if (!await head.exists()) return null;
  try {
    final contents = (await head.readAsString()).trim();
    if (!contents.startsWith('ref:')) {
      return contents.isEmpty ? null : contents;
    }
    final ref = contents.substring(4).trim();
    final refFile = File(p.join(flutterRoot, '.git', ref));
    if (await refFile.exists()) {
      final sha = (await refFile.readAsString()).trim();
      return sha.isEmpty ? null : sha;
    }
  } catch (_) {}
  return null;
}

class FlutterToolsCacheException implements Exception {
  const FlutterToolsCacheException(this.message);

  final String message;

  @override
  String toString() => message;
}
