import 'package:appstudio/toolchain/install_plan.dart';
import 'package:appstudio/ui/settings/add_provider_dialog.dart';
import 'package:appstudio/ui/settings/providers_settings_pane.dart';
import 'package:appstudio/ui/settings/settings_dialog.dart';
import 'package:appstudio/ui/toolchain/tools_view.dart';
import 'package:widgetbook/widgetbook.dart';

import '../fakes/providers.dart';
import '../fakes/tools.dart';
import '../host.dart';
import '../studio_window.dart';

DialogUseCase _settings(ToolsView tools) => DialogUseCase(
      backdrop: const StudioWindowMock(),
      dialog: SettingsDialog(
        agent: FakeProvidersView(),
        toolchains: tools,
        initialTab: SettingsTab.tools,
      ),
    );

final settingsFolder = WidgetbookFolder(
  name: 'Settings',
  children: [
    WidgetbookComponent(
      name: 'Tools',
      useCases: [
        WidgetbookUseCase(
          name: 'Everything installed',
          builder: (_) => _settings(FakeToolsView(inventory: completeInventory)),
        ),
        WidgetbookUseCase(
          name: 'Tools missing',
          builder: (_) => _settings(
            FakeToolsView(inventory: mixedInventory, plan: previewPlan),
          ),
        ),
        WidgetbookUseCase(
          name: 'Tools missing, versions not looked up yet',
          builder: (_) => _settings(
            FakeToolsView(inventory: mixedInventory, plan: InstallPlan.empty),
          ),
        ),
        WidgetbookUseCase(
          name: 'Your Flutter needs updating',
          builder: (_) =>
              _settings(FakeToolsView(inventory: manualUpdateInventory)),
        ),
        WidgetbookUseCase(
          name: 'Installing',
          builder: (_) => _settings(
            FakeToolsView(
              inventory: emptyInventory,
              progress: downloadingProgress,
              isInstalling: true,
              isBusy: true,
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'Install failed',
          builder: (_) => _settings(
            FakeToolsView(
              inventory: mixedInventory,
              installError: 'dart install serverpod_cli failed.',
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'Shell App Studio cannot edit',
          builder: (_) => _settings(
            FakeToolsView(
              inventory: completeInventory,
              shellProfileLabel: null,
              manualPathLines: const [
                r'export PATH="$HOME/develop/flutter/bin:$PATH"',
                r'export PATH="$PATH":"$HOME/Library/Application Support/Dart/install/bin"',
              ],
            ),
          ),
        ),
      ],
    ),
    // Dormant behind `kOpenCodeAgentEnabled`, and kept here so the copy can be
    // reviewed before it comes back.
    WidgetbookComponent(
      name: 'Providers (agent switched off)',
      useCases: [
        WidgetbookUseCase(
          name: 'Two connected',
          builder: (_) => ComponentCanvas(
            width: 580,
            child: ProvidersSettingsPane(agent: connectedProvidersFake()),
          ),
        ),
        WidgetbookUseCase(
          name: 'None connected',
          builder: (_) => ComponentCanvas(
            width: 580,
            child: ProvidersSettingsPane(agent: FakeProvidersView()),
          ),
        ),
        WidgetbookUseCase(
          name: 'Waiting for the agent',
          builder: (_) => ComponentCanvas(
            width: 580,
            child: ProvidersSettingsPane(
              agent: FakeProvidersView(agentReady: false),
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'Add provider',
          builder: (_) => DialogUseCase(
            backdrop: const StudioWindowMock(),
            dialog: AddProviderDialog(
              connected: const {'anthropic'},
              onConnect: (_, _) async => null,
            ),
          ),
        ),
      ],
    ),
  ],
);
