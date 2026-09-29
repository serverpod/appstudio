import 'package:appstudio/preview/preview_device.dart';
import 'package:appstudio/preview/preview_phase.dart';
import 'package:appstudio/preview/registration_code_toast.dart';
import 'package:appstudio/toolchain/tool_status.dart';
import 'package:appstudio/ui/hot_restart_button.dart';
import 'package:appstudio/ui/preview_header_bars.dart';
import 'package:appstudio/ui/project_started_dialog.dart';
import 'package:appstudio/ui/project_startup_dialog.dart';
import 'package:appstudio/ui/publish_to_cloud_button.dart';
import 'package:flutter/material.dart';
import 'package:widgetbook/widgetbook.dart';

import '../fakes/project.dart';
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
          name: 'Server failed to start',
          builder: (_) => screen(
            const StudioWindowMock(
              phase: PreviewPhase.failed,
              errorMessage: 'The server exited with code 1. See the server '
                  'log for details.',
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
      name: 'Hot restart is coming soon',
      useCases: [
        WidgetbookUseCase(
          name: 'Default',
          builder: (_) => _overStudio(const HotRestartComingSoonDialog()),
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
        WidgetbookUseCase(
          name: 'Compact window control bar',
          builder: (_) => ComponentCanvas(
            width: null,
            child: CompactControlBar(
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
