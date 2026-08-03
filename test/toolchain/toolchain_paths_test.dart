import 'dart:io';

import 'package:appstudio/toolchain/toolchain_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The rename AppStudio → App Studio moved the managed toolchain directory.
/// Getting this wrong strands up to ~1.9 GB of downloaded tools and silently
/// re-prompts every existing user to download them again, so the migration is
/// covered here rather than trusted.
void main() {
  late Directory tmp;
  late ToolchainPaths paths;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('toolchain_paths');
    paths = ToolchainPaths(p.join(tmp.path, kAppSupportDirName));
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Directory legacyDir() => Directory(paths.legacyAppSupportRoot);

  /// A stand-in for an installed toolchain: one file deep in the tree.
  Future<File> seed(Directory root, String content) async {
    final file = File(p.join(root.path, 'toolchain', 'flutter', 'marker'));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    return file;
  }

  test('legacy root sits alongside the current one', () {
    expect(p.basename(paths.appSupportRoot), 'App Studio');
    expect(p.basename(paths.legacyAppSupportRoot), 'AppStudio');
    expect(
      p.dirname(paths.legacyAppSupportRoot),
      p.dirname(paths.appSupportRoot),
    );
  });

  test('moves an existing install, contents intact', () async {
    await seed(legacyDir(), 'installed');

    expect(await paths.migrateLegacyDirectory(), isTrue);
    expect(await legacyDir().exists(), isFalse);
    expect(
      await File(
        p.join(paths.appSupportRoot, 'toolchain', 'flutter', 'marker'),
      ).readAsString(),
      'installed',
    );
  });

  test('does nothing when there is no legacy directory', () async {
    expect(await paths.migrateLegacyDirectory(), isFalse);
    expect(await Directory(paths.appSupportRoot).exists(), isFalse);
  });

  test('never clobbers a directory that is already in place', () async {
    await seed(legacyDir(), 'old');
    await seed(Directory(paths.appSupportRoot), 'current');

    expect(await paths.migrateLegacyDirectory(), isFalse);
    // The one the app is actually using has to survive untouched.
    expect(
      await File(
        p.join(paths.appSupportRoot, 'toolchain', 'flutter', 'marker'),
      ).readAsString(),
      'current',
    );
    expect(await legacyDir().exists(), isTrue);
  });

  test('is idempotent — a second call is a no-op', () async {
    await seed(legacyDir(), 'installed');

    expect(await paths.migrateLegacyDirectory(), isTrue);
    expect(await paths.migrateLegacyDirectory(), isFalse);
  });

  test('reports false rather than throwing when the move cannot happen',
      () async {
    // Legacy exists but is a file, so rename onto a directory path fails.
    // A failed migration must degrade to "nothing installed", never to a
    // crash during startup.
    final legacy = File(paths.legacyAppSupportRoot);
    await legacy.writeAsString('not a directory');

    expect(await paths.migrateLegacyDirectory(), isFalse);
  });
}
