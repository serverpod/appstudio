import 'package:appstudio/toolchain/install_plan.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/toolchain/tool_version.dart';
import 'package:appstudio/ui/toolchain/toolchain_notices.dart';
import 'package:appstudio/ui/toolchain/toolchain_setup_dialog.dart';
import 'package:appstudio/ui/toolchain/toolchain_setup_screen.dart';
import 'package:flutter/widgets.dart';
import 'package:widgetbook/widgetbook.dart';

import '../fakes/project.dart';
import '../fakes/tools.dart';
import '../host.dart';

/// A Flutter the user installed, on the beta channel — the other reason setup
/// asks them to run a command.
final _betaFlutterInventory = ToolchainInventory(
  manifest: previewManifest,
  tools: {
    ...manualUpdateInventory.tools,
    ToolId.flutter: ToolStatus(
      spec: previewManifest[ToolId.flutter]!,
      action: ToolAction.manual,
      candidates: [
        ToolCandidate(
          id: ToolId.flutter,
          source: ToolSource.host,
          fitness: ToolFitness.wrongVersion,
          root: homePath('flutter'),
          detectedVersion: ToolVersion.tryParse('3.48.0-0.1.pre'),
          reason: 'on channel beta (needs stable)',
          facts: const {'channel': 'beta'},
        ),
      ],
    ),
  },
);

/// App Studio installed this Flutter, so it updates it with `flutter upgrade`
/// itself rather than asking.
final _ownFlutterOutdatedInventory = ToolchainInventory(
  manifest: previewManifest,
  tools: {
    ...completeInventory.tools,
    ToolId.flutter: ToolStatus(
      spec: previewManifest[ToolId.flutter]!,
      action: ToolAction.update,
      candidates: [
        ToolCandidate(
          id: ToolId.flutter,
          source: ToolSource.appStudio,
          fitness: ToolFitness.wrongVersion,
          root: homePath('flutter'),
          detectedVersion: ToolVersion.tryParse('3.46.1'),
        ),
      ],
    ),
  },
);

final _updatePlan = InstallPlan({
  ToolId.flutter: PlannedTool(
    id: ToolId.flutter,
    version: ToolVersion.tryParse('3.47.5'),
  ),
});

/// One first-run dialog, over the landing backdrop it appears on.
DialogUseCase _onLanding(Widget dialog) =>
    DialogUseCase(backdrop: landingBackdrop, dialog: dialog);

final firstRunFolder = WidgetbookFolder(
  name: 'First run',
  children: [
    WidgetbookComponent(
      name: 'Setup screen',
      useCases: [
        WidgetbookUseCase(
          name: 'Looking up versions',
          builder: (_) => screen(
            ToolchainSetupScreen(
              toolchains: FakeToolsView(
                inventory: emptyInventory,
                preflightNeverAnswers: true,
              ),
            ),
          ),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Legacy install notice',
      useCases: [
        WidgetbookUseCase(
          name: 'Default',
          builder: (_) => _onLanding(const LegacyInstallNotice()),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Update your Flutter',
      useCases: [
        WidgetbookUseCase(
          name: 'Too old',
          builder: (_) => _onLanding(
            ManualUpdateDialog(
              toolchains: FakeToolsView(inventory: manualUpdateInventory),
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'On the beta channel',
          builder: (_) => _onLanding(
            ManualUpdateDialog(
              toolchains: FakeToolsView(inventory: _betaFlutterInventory),
            ),
          ),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Install plan',
      useCases: [
        for (final (name, tools) in [
          ('Nothing installed', FakeToolsView(inventory: emptyInventory)),
          ('Partly installed', FakeToolsView(inventory: mixedInventory)),
          (
            'Updating a Flutter App Studio installed',
            FakeToolsView(
              inventory: _ownFlutterOutdatedInventory,
              plan: _updatePlan,
            ),
          ),
          (
            'After a failed install',
            FakeToolsView(
              inventory: emptyInventory,
              installError: 'dart install serverpod_cli failed.',
            ),
          ),
          (
            'Shell App Studio cannot edit',
            FakeToolsView(inventory: emptyInventory, shellProfileLabel: null),
          ),
        ])
          WidgetbookUseCase(
            name: name,
            builder: (_) => _onLanding(ToolchainSetupDialog(toolchains: tools)),
          ),
      ],
    ),
    WidgetbookComponent(
      name: 'Installing',
      useCases: [
        for (final (name, progress) in [
          ('Waiting for Apple\'s installer', waitingForAppleProgress),
          ('Downloading Flutter', downloadingProgress),
          ('Setting up Flutter', settingUpFlutterProgress),
          ('Installing the Serverpod CLI', installingServerpodProgress),
          ('Finishing up', finishingProgress),
        ])
          WidgetbookUseCase(
            name: name,
            builder: (_) => _onLanding(
              ToolchainSetupDialog(
                toolchains: FakeToolsView(
                  inventory: emptyInventory,
                  progress: progress,
                  isInstalling: true,
                  isBusy: true,
                ),
              ),
            ),
          ),
      ],
    ),
    WidgetbookComponent(
      name: 'Setup error',
      useCases: [
        WidgetbookUseCase(
          name: 'No network',
          builder: (_) => _onLanding(
            const ToolchainSetupErrorDialog(
              message: 'Could not reach flutter.dev to look up the latest '
                  'Flutter release.',
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'Old tools could not be removed',
          builder: (_) => _onLanding(
            const ToolchainSetupErrorDialog(
              title: 'Could not remove the old tools',
              message: 'Could not remove the tools an earlier version '
                  'installed: Permission denied.',
            ),
          ),
        ),
      ],
    ),
  ],
);
