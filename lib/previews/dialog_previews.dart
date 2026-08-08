import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../ui/project_startup_dialog.dart';
import '../ui/settings/settings_dialog.dart';
import '../ui/toolchain/toolchain_setup_dialog.dart';
import '../ui/toolchain/toolchain_setup_screen.dart';
import '../ui/uninstall/uninstall_confirm_dialog.dart';
import '../ui/uninstall/uninstalled_screen.dart';
import '../uninstall/uninstall_result.dart';
import 'preview_app.dart';
import 'preview_data.dart';

/// Widget previews for the dialogs and full-screen states.
///
/// Run with `flutter widget-preview start`.
///
/// Everything here is driven by the fakes in `preview_data.dart`, which
/// implement the same [ToolsView] / [ProvidersView] interfaces the app uses.
/// The states worth looking at are the ones that are awkward to reach by hand:
/// a download in flight, a partly-failed uninstall, a first run with nothing
/// installed.

// --- Settings ---------------------------------------------------------------

@Preview(name: 'Providers — connected', group: 'Settings')
Widget settingsProviders() => previewShell(
      SettingsDialog(
        agent: connectedProvidersFake(),
        toolchains: FakeToolsView(),
      ),
    );

@Preview(name: 'Providers — no keys yet', group: 'Settings')
Widget settingsProvidersEmpty() => previewShell(
      SettingsDialog(
        agent: FakeProvidersView(),
        toolchains: FakeToolsView(),
      ),
    );

/// What Settings shows while `opencode serve` is still coming up — the state
/// you hit by opening Settings during a cold project's first build.
@Preview(name: 'Providers — waiting for agent', group: 'Settings')
Widget settingsProvidersWaiting() => previewShell(
      SettingsDialog(
        agent: FakeProvidersView(agentReady: false),
        toolchains: FakeToolsView(),
      ),
    );

@Preview(name: 'Tools — all installed', group: 'Settings')
Widget settingsToolsComplete() => previewShell(
      SettingsDialog(
        agent: connectedProvidersFake(),
        toolchains: FakeToolsView(inventory: completeInventory),
        initialTab: SettingsTab.tools,
      ),
    );

/// One tool missing and a host copy too old — the state that produces both the
/// warning banner and the "upgrade it yourself" hint.
@Preview(name: 'Tools — missing and outdated', group: 'Settings')
Widget settingsToolsMixed() => previewShell(
      SettingsDialog(
        agent: connectedProvidersFake(),
        toolchains: FakeToolsView(inventory: mixedInventory),
        initialTab: SettingsTab.tools,
      ),
    );

@Preview(name: 'Tools — downloading', group: 'Settings')
Widget settingsToolsInstalling() => previewShell(
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

@Preview(name: 'Tools — install failed', group: 'Settings')
Widget settingsToolsError() => previewShell(
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

@Preview(name: 'Tools — dark', group: 'Settings')
Widget settingsToolsDark() => previewShell(
      SettingsDialog(
        agent: connectedProvidersFake(),
        toolchains: FakeToolsView(inventory: mixedInventory),
        initialTab: SettingsTab.tools,
      ),
      dark: true,
    );

// --- First run --------------------------------------------------------------

@Preview(name: 'Toolchain setup', group: 'First run')
Widget toolchainSetup() => previewShell(
      ToolchainSetupDialog(toolchains: FakeToolsView(inventory: emptyInventory)),
    );

@Preview(name: 'Toolchain setup — dark', group: 'First run')
Widget toolchainSetupDark() => previewShell(
      ToolchainSetupDialog(toolchains: FakeToolsView(inventory: emptyInventory)),
      dark: true,
    );

/// The screen the dialog sits on, held at the spinner it shows while the plan
/// is still being fetched.
@Preview(name: 'Setup screen — loading', group: 'First run')
Widget toolchainSetupLoading() => previewShell(
      ToolchainSetupScreen(
        toolchains: FakeToolsView(
          inventory: emptyInventory,
          preflightDelay: const Duration(days: 1),
        ),
      ),
    );

/// What a first run with no network looks like — the one state that decides
/// whether someone can get started at all.
@Preview(name: 'Setup screen — offline', group: 'First run')
Widget toolchainSetupOffline() => previewShell(
      ToolchainSetupScreen(
        toolchains: FakeToolsView(
          inventory: emptyInventory,
          preflightError: 'Could not reach the download server for Flutter SDK '
              'and Serverpod CLI. Check your internet connection and try again.',
        ),
      ),
    );

// --- Uninstall --------------------------------------------------------------

@Preview(name: 'Confirm', group: 'Uninstall')
Widget uninstallConfirm() => previewShell(
      UninstallConfirmDialog(
        supportRootLabel: '~/Library/Application Support/App Studio',
        measureBytes: previewSupportBytes,
      ),
    );

/// Must be a static, non-private function to be usable from an annotation.
Future<int?> previewSupportBytes() async => 1_932_735_283;

@Preview(name: 'Done — clean', group: 'Uninstall')
Widget uninstalledClean() => previewShell(
      const UninstalledScreen(result: UninstallResult(failures: [])),
    );

@Preview(name: 'Done — clean (dark)', group: 'Uninstall')
Widget uninstalledCleanDark() => previewShell(
      const UninstalledScreen(result: UninstallResult(failures: [])),
      dark: true,
    );

/// The path nobody sees until something has already gone wrong, which is
/// exactly why it is worth being able to look at.
@Preview(name: 'Done — partial failure', group: 'Uninstall')
Widget uninstalledWithFailures() => previewShell(
      const UninstalledScreen(
        result: UninstallResult(
          failures: [
            'removing the shell PATH entry',
            'deleting the App Studio support folder',
          ],
        ),
      ),
    );

// --- Project startup --------------------------------------------------------

/// Shown every time a project is opened until the user turns it off. The first
/// build of a full Serverpod stack is long enough to read as a hang.
@Preview(name: 'Startup notice', group: 'Project')
Widget projectStartupNotice() => previewShell(const ProjectStartupDialog());
