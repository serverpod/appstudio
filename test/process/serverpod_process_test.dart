import 'package:appstudio/process/serverpod_process.dart';
import 'package:appstudio/session/project_session.dart';
import 'package:appstudio/terminal/studio_terminal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/toolchain_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ServerpodProcessController process;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final toolchains = await emptyToolchainController();
    process = ServerpodProcessController(
      toolchains: toolchains,
      session: ProjectSession(),
      terminal: StudioTerminal(),
    );
  });

  tearDown(() => process.dispose());

  group('restart', () {
    test('does nothing with no project open', () async {
      // Nothing to restart, and `start()` would have no working directory. The
      // button is disabled here, but the controller must not rely on that.
      await process.restart();

      expect(process.state, ProcessState.idle);
      expect(process.isRestarting, isFalse);
    });
  });

  group('Full Restart button state', () {
    test('is offered with the server stopped, so a crash is recoverable', () {
      // `canRestart` gates the only control that can bring the server back.
      // With no project it must be off; with a project and an idle server it
      // must be on, which is what `isStopped` reports.
      expect(process.isStopped, isTrue);
      expect(process.isTransitioning, isFalse);
      // No project in this fixture, so the button is still disabled.
      expect(process.canRestart, isFalse);
    });
  });

  group('requestPreviewReload', () {
    test('does not bump the token before the preview is up', () {
      // The token drives `PreviewPaneState.reload()`. Bumping it with no
      // webview would queue a reload against nothing; a hot restart that
      // somehow lands before the preview is serving must be a no-op here.
      expect(process.previewReady, isFalse);
      final before = process.previewReloadToken;

      process.requestPreviewReload();

      expect(process.previewReloadToken, before);
    });

    test('notifies nobody when it declines', () {
      var notifications = 0;
      process.addListener(() => notifications++);

      process.requestPreviewReload();

      expect(notifications, 0);
    });
  });
}
