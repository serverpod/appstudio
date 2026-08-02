import 'dart:io';

import 'package:appstudio/toolchain/flutter_tools_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;

  /// The parts of a Flutter SDK this function actually touches.
  Future<void> buildFakeSdk({
    String? revision = 'c9a6c484230f8b5e408ec57be1ef71dee1e77020',
    bool withSnapshot = true,
    bool withVersionJson = true,
    bool withGitHead = false,
  }) async {
    await Directory('${root.path}/bin/cache').create(recursive: true);
    await Directory('${root.path}/packages/flutter_tools/.dart_tool')
        .create(recursive: true);

    if (withSnapshot) {
      await File('${root.path}/bin/cache/flutter_tools.snapshot')
          .writeAsString('snapshot');
    }
    if (withVersionJson) {
      await File('${root.path}/bin/cache/flutter.version.json').writeAsString(
        '{"frameworkVersion":"3.44.2","channel":"stable",'
        '"frameworkRevision":"$revision"}',
      );
    }
    if (withGitHead) {
      await Directory('${root.path}/.git/refs/heads').create(recursive: true);
      await File('${root.path}/.git/HEAD')
          .writeAsString('ref: refs/heads/stable\n');
      await File('${root.path}/.git/refs/heads/stable')
          .writeAsString('$revision\n');
    }

    // pubspec.yaml newer than pubspec.lock is what triggers a rebuild.
    await File('${root.path}/packages/flutter_tools/pubspec.lock')
        .writeAsString('lock');
    await File('${root.path}/packages/flutter_tools/pubspec.yaml')
        .writeAsString('name: flutter_tools');
    await File('${root.path}/packages/flutter_tools/.dart_tool/package_config.json')
        .writeAsString('{"packages":[]}');
    await File('${root.path}/packages/flutter_tools/pubspec.lock')
        .setLastModified(DateTime.now().subtract(const Duration(days: 2)));
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('appstudio_flutter_cache');
  });

  tearDown(() => root.delete(recursive: true));

  test('writes the stamp shared.sh expects', () async {
    await buildFakeSdk();
    await ensureFlutterToolsCache(root.path);

    final stamp =
        await File('${root.path}/bin/cache/flutter_tools.stamp').readAsString();
    // Matches shared.sh's compilekey when FLUTTER_TOOL_ARGS is unset.
    expect(stamp, 'c9a6c484230f8b5e408ec57be1ef71dee1e77020:\n');
  });

  test('needs no git — the revision comes from flutter.version.json', () async {
    await buildFakeSdk(withGitHead: false);
    // No .git at all: installing Flutter must not depend on git being there.
    expect(Directory('${root.path}/.git').existsSync(), isFalse);

    await ensureFlutterToolsCache(root.path);

    expect(
      File('${root.path}/bin/cache/flutter_tools.stamp').readAsStringSync(),
      startsWith('c9a6c48'),
    );
  });

  test('falls back to .git/HEAD on an SDK without the version json', () async {
    await buildFakeSdk(withVersionJson: false, withGitHead: true);
    await ensureFlutterToolsCache(root.path);

    expect(
      File('${root.path}/bin/cache/flutter_tools.stamp').readAsStringSync(),
      'c9a6c484230f8b5e408ec57be1ef71dee1e77020:\n',
    );
  });

  test('makes pubspec.lock newer than pubspec.yaml', () async {
    await buildFakeSdk();
    await ensureFlutterToolsCache(root.path);

    final lock = File('${root.path}/packages/flutter_tools/pubspec.lock');
    final yaml = File('${root.path}/packages/flutter_tools/pubspec.yaml');
    expect(
      lock.lastModifiedSync().isAfter(yaml.lastModifiedSync()) ||
          lock.lastModifiedSync() == yaml.lastModifiedSync(),
      isTrue,
      reason: 'a lock older than the yaml makes shared.sh rebuild the tool',
    );
  });

  test('removes .dart_tool, which points at the packing machine', () async {
    await buildFakeSdk();
    expect(
      Directory('${root.path}/packages/flutter_tools/.dart_tool').existsSync(),
      isTrue,
    );

    await ensureFlutterToolsCache(root.path);

    // Left in place, the first flutter run fails with "'File' isn't a type".
    expect(
      Directory('${root.path}/packages/flutter_tools/.dart_tool').existsSync(),
      isFalse,
    );
  });

  test('fails loudly when the snapshot is missing', () async {
    await buildFakeSdk(withSnapshot: false);
    await expectLater(
      ensureFlutterToolsCache(root.path),
      throwsA(isA<FlutterToolsCacheException>()),
    );
  });

  test('fails loudly when the revision cannot be determined', () async {
    await buildFakeSdk(withVersionJson: false, withGitHead: false);
    await expectLater(
      ensureFlutterToolsCache(root.path),
      throwsA(isA<FlutterToolsCacheException>()),
    );
  });
}
