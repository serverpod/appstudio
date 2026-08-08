@Tags(['golden'])
library;

import 'package:appstudio/previews/preview_data.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/project_startup_dialog.dart';
import 'package:appstudio/ui/settings/settings_dialog.dart';
import 'package:appstudio/ui/toolchain/toolchain_setup_dialog.dart';
import 'package:appstudio/ui/uninstall/uninstall_confirm_dialog.dart';
import 'package:appstudio/ui/uninstall/uninstalled_screen.dart';
import 'package:appstudio/uninstall/uninstall_result.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shad/shad.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'font_loader.dart';

/// Pixel snapshots of every dialog, driven by the SAME fakes as the widget
/// previews in `lib/previews/`. One set of fixtures, two consumers: if a
/// preview state is worth looking at by hand, it is worth locking down.
///
/// Regenerate after an intentional change:
///
///     flutter test --update-goldens test/golden
///
/// and *look at the diff* before committing it — that is the whole point.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(loadSystemFonts);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  /// Renders [child] at a fixed size and compares against `goldens/<name>.png`.
  ///
  /// The size is pinned rather than inherited from the test surface so a
  /// different host or Flutter version cannot silently reflow the layout and
  /// invalidate every golden at once.
  Future<void> expectGolden(
    WidgetTester tester,
    String name,
    Widget child, {
    bool dark = false,
    Size size = const Size(760, 900),
  }) async {
    tester.view.physicalSize = size * tester.view.devicePixelRatio;
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = size * 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      // An explicit boundary to capture: ShadApp is not a MaterialApp, and
      // matchesGoldenFile needs a render object it can rasterize.
      RepaintBoundary(
        key: const Key('golden'),
        child: ShadApp(
          debugShowCheckedModeBanner: false,
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          home: Scaffold(body: Center(child: child)),
        ),
      ),
    );
    // pump, not pumpAndSettle: the panes kick off async work in a post-frame
    // callback and shadcn's tab indicator animates, so settling can never
    // complete. Two fixed pumps give a deterministic frame.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byKey(const Key('golden')),
      matchesGoldenFile('goldens/$name.png'),
    );
  }

  group('Settings', () {
    testWidgets('providers with keys', (tester) async {
      await expectGolden(
        tester,
        'settings_providers',
        SettingsDialog(
          agent: connectedProvidersFake(),
          toolchains: FakeToolsView(),
        ),
      );
    });

    testWidgets('providers with no keys', (tester) async {
      await expectGolden(
        tester,
        'settings_providers_empty',
        SettingsDialog(
          agent: FakeProvidersView(),
          toolchains: FakeToolsView(),
        ),
      );
    });

    testWidgets('tools complete', (tester) async {
      await expectGolden(
        tester,
        'settings_tools_complete',
        SettingsDialog(
          agent: connectedProvidersFake(),
          toolchains: FakeToolsView(inventory: completeInventory),
          initialTab: SettingsTab.tools,
        ),
      );
    });

    testWidgets('tools missing and outdated', (tester) async {
      await expectGolden(
        tester,
        'settings_tools_mixed',
        SettingsDialog(
          agent: connectedProvidersFake(),
          toolchains: FakeToolsView(inventory: mixedInventory),
          initialTab: SettingsTab.tools,
        ),
      );
    });

    testWidgets('tools downloading', (tester) async {
      await expectGolden(
        tester,
        'settings_tools_installing',
        SettingsDialog(
          agent: connectedProvidersFake(),
          toolchains: FakeToolsView(
            inventory: emptyInventory,
            progress: downloadingProgress,
            isInstalling: true,
            isBusy: true,
          ),
          initialTab: SettingsTab.tools,
        ),
      );
    });

    testWidgets('tools install failed', (tester) async {
      await expectGolden(
        tester,
        'settings_tools_error',
        SettingsDialog(
          agent: connectedProvidersFake(),
          toolchains: FakeToolsView(
            inventory: mixedInventory,
            installError: 'Download failed: connection closed before the '
                'archive finished (Flutter SDK).',
          ),
          initialTab: SettingsTab.tools,
        ),
      );
    });

    testWidgets('tools dark', (tester) async {
      await expectGolden(
        tester,
        'settings_tools_dark',
        SettingsDialog(
          agent: connectedProvidersFake(),
          toolchains: FakeToolsView(inventory: mixedInventory),
          initialTab: SettingsTab.tools,
        ),
        dark: true,
      );
    });
  });

  group('First run', () {
    testWidgets('toolchain setup', (tester) async {
      await expectGolden(
        tester,
        'toolchain_setup',
        ToolchainSetupDialog(
          toolchains: FakeToolsView(inventory: emptyInventory),
        ),
      );
    });
  });

  group('Project', () {
    testWidgets('startup notice', (tester) async {
      await expectGolden(
        tester,
        'project_startup_notice',
        const ProjectStartupDialog(),
        // Must stay above shad's `sm` breakpoint (640 of *screen*, not dialog):
        // below it the dialog switches to its tiny layout and stretches OK to
        // full width, which the real window never does.
        size: const Size(760, 420),
      );
    });
  });

  group('Uninstall', () {
    testWidgets('confirm', (tester) async {
      await expectGolden(
        tester,
        'uninstall_confirm',
        UninstallConfirmDialog(
          supportRootLabel: '~/Library/Application Support/App Studio',
          measureBytes: () async => 1_932_735_283,
        ),
        size: const Size(720, 560),
      );
    });

    testWidgets('done clean', (tester) async {
      await expectGolden(
        tester,
        'uninstalled_clean',
        const UninstalledScreen(result: UninstallResult(failures: [])),
        size: const Size(620, 460),
      );
    });

    testWidgets('done clean dark', (tester) async {
      await expectGolden(
        tester,
        'uninstalled_clean_dark',
        const UninstalledScreen(result: UninstallResult(failures: [])),
        dark: true,
        size: const Size(620, 460),
      );
    });

    testWidgets('done with failures', (tester) async {
      await expectGolden(
        tester,
        'uninstalled_failures',
        const UninstalledScreen(
          result: UninstallResult(
            failures: [
              'removing the shell PATH entry',
              'deleting the App Studio support folder',
            ],
          ),
        ),
        size: const Size(620, 520),
      );
    });
  });
}
