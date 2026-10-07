import 'package:appstudio/preview/preview_mode_controller.dart';
import 'package:appstudio/preview/preview_theme.dart';
import 'package:appstudio/process/serverpod_process.dart';
import 'package:appstudio/session/project_session.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/preview_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_compact_window.dart';
import 'support/toolchain_support.dart';
import 'package:shad/shad.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('backdrop follows the previewed app brightness', () {
    expect(previewBackdropColor(Brightness.light), const Color(0xFFFFFFFF));
    expect(previewBackdropColor(Brightness.dark), const Color(0xFF000000));
  });

  Color backdropOf(WidgetTester tester) {
    final box = tester.widget<ColoredBox>(
      find.byKey(const ValueKey('preview-backdrop')),
    );
    return box.color;
  }

  /// The shell theme is deliberately the opposite of the preview default, so a
  /// backdrop wired to the wrong one would show up here.
  Future<void> pumpPane(WidgetTester tester) async {
    late final ServerpodProcessController process;
    await tester.runAsync(() async {
      process = ServerpodProcessController(
        toolchains: await emptyToolchainController(),
        session: ProjectSession(),
      );
    });
    addTearDown(process.dispose);

    await tester.pumpWidget(
      ShadApp(
        theme: buildDarkTheme(),
        home: Scaffold(
          body: PreviewPane(
            process: process,
            mode: PreviewModeController(window: FakeCompactWindow()),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  /// The mesh gradient behind the preview leaves a zero-duration timer queued;
  /// unmounting and pumping once flushes it so the test can finish clean.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('starts white for a light preview', (tester) async {
    await pumpPane(tester);

    expect(backdropOf(tester), const Color(0xFFFFFFFF));
    await unmount(tester);
  });

  testWidgets('turns black when the preview is switched to dark',
      (tester) async {
    await pumpPane(tester);

    await tester.tap(find.byIcon(LucideIcons.moon));
    await tester.pump();
    expect(backdropOf(tester), const Color(0xFF000000));

    await tester.tap(find.byIcon(LucideIcons.sun));
    await tester.pump();
    expect(backdropOf(tester), const Color(0xFFFFFFFF));
    await unmount(tester);
  });
}
