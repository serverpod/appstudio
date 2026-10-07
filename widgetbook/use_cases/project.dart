import 'package:appstudio/preview/preview_device.dart';
import 'package:appstudio/preview/preview_phase.dart';
import 'package:appstudio/preview/registration_code_toast.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/runner/runner_actions_view.dart';
import 'package:appstudio/runner/server_status.dart';
import 'package:appstudio/ui/hot_restart_button.dart';
import 'package:appstudio/ui/server_log/log_view_controller.dart';
import 'package:appstudio/ui/migration_commands.dart';
import 'package:appstudio/ui/server_log/server_log_view.dart';
import 'package:appstudio/ui/preview_header_bars.dart';
import 'package:appstudio/ui/project_started_dialog.dart';
import 'package:appstudio/ui/project_startup_dialog.dart';
import 'package:appstudio/ui/publish_to_cloud_button.dart';
import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import '../fakes/project.dart';
import '../fakes/runner.dart';
import '../fakes/tools.dart';
import '../host.dart';
import '../studio_window.dart';

/// Flutter is missing, so the toolbar's warning badge shows.
final _missingFlutterInventory = ToolchainInventory(
  manifest: previewManifest,
  tools: {
    ...completeInventory.tools,
    ToolId.flutter: ToolStatus(
      spec: previewManifest[ToolId.flutter]!,
      candidates: const [],
      action: ToolAction.install,
    ),
  },
);

/// One dialog, over an open project.
Widget _overStudio(
  Widget dialog, {
  PreviewPhase phase = PreviewPhase.ready,
}) =>
    DialogUseCase(backdrop: StudioWindowMock(phase: phase), dialog: dialog);

final projectFolder = WidgetbookFolder(
  name: 'Open project',
  children: [
    WidgetbookComponent(
      name: 'Studio window',
      useCases: [
        for (final (name, phase) in [
          ('Fetching packages', PreviewPhase.fetchingDependencies),
          ('Booting Serverpod', PreviewPhase.startingServerpod),
          ('Loading the app', PreviewPhase.loadingApp),
          ('Running', PreviewPhase.ready),
          ('Stopped', PreviewPhase.idle),
        ])
          WidgetbookUseCase(
            name: name,
            builder: (_) => screen(StudioWindowMock(phase: phase)),
          ),
        WidgetbookUseCase(
          name: 'Project failed to build',
          builder: (_) => screen(
            const StudioWindowMock(
              phase: PreviewPhase.failed,
              errorMessage: 'The project failed to build, so the server is '
                  'not running. The server log has the errors — it starts '
                  'again as soon as the project builds.',
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'App log tab',
          builder: (_) => screen(
            const StudioWindowMock(
              logTab: LogTab(AppLogSource(sampleAppId)),
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'Hot restarting',
          builder: (_) => screen(
            StudioWindowMock(
              actions: FakeRunnerActions(
                runningAction: RunnerAction.hotRestart,
              ),
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'Registration code',
          builder: (_) => screen(
            const StudioWindowMock(registrationCode: '842 117'),
          ),
        ),
        WidgetbookUseCase(
          name: 'Restarting',
          builder: (_) => screen(
            StudioWindowMock(
              phase: PreviewPhase.startingServerpod,
              process: FakeFullRestart(isTransitioning: true),
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'A tool went missing',
          builder: (_) => screen(
            StudioWindowMock(
              tools: FakeToolsView(inventory: _missingFlutterInventory),
            ),
          ),
        ),
        WidgetbookUseCase(
          name: 'No external editor',
          builder: (_) => screen(
            StudioWindowMock(editors: FakeExternalEditors()),
          ),
        ),
        WidgetbookUseCase(
          name: 'Desktop preview',
          builder: (_) => screen(
            const StudioWindowMock(viewMode: PreviewViewMode.desktop),
          ),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Starting your project',
      useCases: [
        WidgetbookUseCase(
          name: 'Default',
          builder: (_) => _overStudio(
            phase: PreviewPhase.startingServerpod,
            ProjectStartupDialog(process: FakeProjectReady()),
          ),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Your project has started',
      useCases: [
        WidgetbookUseCase(
          name: 'Cursor',
          builder: (_) =>
              _overStudio(const ProjectStartedDialog(editor: cursorEditor)),
        ),
        WidgetbookUseCase(
          name: 'Claude Code',
          builder: (_) =>
              _overStudio(const ProjectStartedDialog(editor: claudeEditor)),
        ),
        WidgetbookUseCase(
          name: 'No editor App Studio can open',
          builder: (_) =>
              _overStudio(const ProjectStartedDialog(editor: null)),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Server log',
      useCases: [
        for (final (name, log) in [
          ('Running', sampleRunnerLog()),
          ('With an error', sampleRunnerLog(failure: true)),
          ('Launching the app', sampleRunnerLog(launching: true)),
          ('Empty', sampleRunnerLog(empty: true)),
        ])
          WidgetbookUseCase(
            name: name,
            builder: (_) => ComponentCanvas(
              width: 640,
              height: 520,
              child: ServerLogView(
                log: log,
                view: LogViewController(),
                source: const ServerLogSource(),
                emptyMessage: 'Waiting for the server to start…',
              ),
            ),
          ),
      ],
    ),
    WidgetbookComponent(
      name: 'Create the migration anyway?',
      useCases: [
        WidgetbookUseCase(
          name: 'Default',
          builder: (_) => _overStudio(
            ForceMigrationDialog(
              kind: 'migration',
              message: refusedMigration.message,
            ),
          ),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Hot restart',
      useCases: [
        for (final (name, actions) in [
          ('Ready', FakeRunnerActions()),
          ('Server not running', FakeRunnerActions(canHotRestart: false)),
          (
            'Hot restarting',
            FakeRunnerActions(runningAction: RunnerAction.hotRestart),
          ),
          (
            'Hot restart failed',
            FakeRunnerActions(
              failedAction: RunnerAction.hotRestart,
              actionError: 'Compilation failed.',
            ),
          ),
        ])
          WidgetbookUseCase(
            name: name,
            builder: (_) => ComponentCanvas(
              width: null,
              child: HotRestartButton(actions: actions),
            ),
          ),
      ],
    ),
    WidgetbookComponent(
      name: 'Publish to Cloud',
      useCases: [
        WidgetbookUseCase(
          name: 'Default',
          builder: (_) => _overStudio(const PublishToCloudDialog()),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Registration code toast',
      useCases: [
        WidgetbookUseCase(
          name: 'Default',
          builder: (_) => ComponentCanvas(
            width: null,
            child: RegistrationCodeToast(code: '842 117', onDismiss: () {}),
          ),
        ),
      ],
    ),
    WidgetbookComponent(
      name: 'Preview header',
      useCases: [
        for (final minimized in [false, true])
          WidgetbookUseCase(
            name: minimized ? 'Minimized (desktop)' : 'Default',
            builder: (_) => ComponentCanvas(
              width: 720,
              child: PreviewHeaderBar(
                previewBrightness: Brightness.light,
                viewMode: minimized
                    ? PreviewViewMode.desktop
                    : PreviewViewMode.phonePortrait,
                minimized: minimized,
                onPreviewThemeChanged: (_) {},
                onViewModeChanged: (_) {},
                onToggleMinimized: () {},
              ),
            ),
          ),
        for (final (name, status) in [
          ('running', const ServerStatus.running()),
          ('loading', const ServerStatus.busy('Compiling server')),
          ('stopped', const ServerStatus.stopped('Stopped')),
        ])
          WidgetbookUseCase(
            name: 'Compact window control bar, $name',
            builder: (_) => ComponentCanvas(
              width: null,
              child: CompactControlBar(
                status: FakeServerStatus(status),
                viewMode: PreviewViewMode.phonePortrait,
                previewBrightness: Brightness.dark,
                onViewModeChanged: (_) {},
                onPreviewThemeChanged: (_) {},
                onExpand: () {},
              ),
            ),
          ),
      ],
    ),
  ],
);
