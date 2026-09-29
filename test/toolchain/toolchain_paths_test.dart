import 'package:appstudio/toolchain/toolchain_paths.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every tool now lands where its own instructions put it, so these paths are
/// promises to the user and to other tools — not internal layout.
void main() {
  final paths = ToolchainPaths.forHome('/Users/alex');

  test('Flutter goes where Flutter\'s macOS instructions extract it', () {
    expect(paths.flutterInstallDir, '/Users/alex/develop/flutter');
  });

  test('dart install puts executables in Application Support/Dart', () {
    expect(
      paths.dartInstallBinDir,
      '/Users/alex/Library/Application Support/Dart/install/bin',
    );
  });

  test('the install record lives with the Serverpod CLI\'s own state', () {
    expect(paths.serverpodStateDir, '/Users/alex/.serverpod');
    expect(
      paths.installRecordFile,
      '/Users/alex/.serverpod/app_studio_installs.json',
    );
  });

  test('legacy paths cover the private toolchain, its shims and the old name',
      () {
    expect(paths.legacyPaths, [
      '/Users/alex/Library/Application Support/App Studio/toolchain',
      '/Users/alex/Library/Application Support/App Studio/bin',
      '/Users/alex/Library/Application Support/AppStudio',
    ]);
  });

  test('legacy paths never include App Studio\'s own data directory', () {
    // Uninstall deletes that separately; setup must not, or it would take the
    // agent's scratch directory and anything else living there with it.
    expect(paths.legacyPaths, isNot(contains(paths.appSupportRoot)));
  });
}
