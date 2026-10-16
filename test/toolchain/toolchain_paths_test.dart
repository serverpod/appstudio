import 'package:appstudio/platform/host_platform.dart';
import 'package:appstudio/toolchain/toolchain_paths.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every tool now lands where its own instructions put it, so these paths are
/// promises to the user and to other tools — not internal layout.
void main() {
  final paths =
      ToolchainPaths.forHome('/Users/alex', host: HostPlatform.macos);

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

  group('on Windows', () {
    final windows = ToolchainPaths.forHome(
      r'C:\Users\alex',
      host: HostPlatform.windows,
    );

    test('Flutter goes where Flutter\'s Windows instructions extract it', () {
      expect(windows.flutterInstallDir, r'C:\Users\alex\develop\flutter');
    });

    test(r'dart install puts executables in AppData\Local\Dart', () {
      expect(
        windows.dartInstallBinDir,
        r'C:\Users\alex\AppData\Local\Dart\install\bin',
      );
    });

    test(r'the pub cache defaults to AppData\Local\Pub\Cache', () {
      expect(windows.defaultPubCache, r'C:\Users\alex\AppData\Local\Pub\Cache');
    });

    test('App Studio keeps its data in roaming AppData', () {
      expect(windows.appSupportRoot, r'C:\Users\alex\AppData\Roaming\App Studio');
    });

    test('the Serverpod state directory is shared with the CLI', () {
      expect(windows.serverpodStateDir, r'C:\Users\alex\.serverpod');
    });

    test('no build ever shipped a toolchain there, so nothing is legacy', () {
      expect(windows.legacyPaths, isEmpty);
      expect(windows.legacyShellFiles, isEmpty);
    });
  });
}
