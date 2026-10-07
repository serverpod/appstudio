/// An open project's window, assembled from the real toolbar, pane headers and
/// preview overlay — the context most dialogs and all the chrome appear in.
///
/// The server log is the real log view, fed a sample runner log rather than a
/// live runner. The preview is a placeholder where CEF would draw the app.
library;

import 'package:appstudio/preview/preview_device.dart';
import 'package:appstudio/preview/preview_hero_gradient.dart';
import 'package:appstudio/preview/preview_phase.dart';
import 'package:appstudio/preview/preview_status_overlay.dart';
import 'package:appstudio/preview/preview_theme.dart';
import 'package:appstudio/preview/registration_code_toast.dart';
import 'package:appstudio/process/full_restart_view.dart';
import 'package:appstudio/session/external_editors_view.dart';
import 'package:appstudio/theme/app_theme.dart';
import 'package:appstudio/ui/preview_header_bars.dart';
import 'package:appstudio/ui/studio_toolbar.dart';
import 'package:appstudio/runner/runner_actions_view.dart';
import 'package:appstudio/runner/runner_log.dart';
import 'package:appstudio/runner/server_status.dart';
import 'package:appstudio/ui/left_pane.dart';
import 'package:appstudio/ui/server_log/log_view_controller.dart';
import 'package:appstudio/ui/server_log/server_log_view.dart';
import 'package:appstudio/ui/toolchain/tools_view.dart';
import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import 'fakes/project.dart';
import 'fakes/runner.dart';
import 'fakes/tools.dart';

class StudioWindowMock extends StatelessWidget {
  const StudioWindowMock({
    super.key,
    this.phase = PreviewPhase.ready,
    this.errorMessage,
    this.tools,
    this.editors,
    this.process,
    this.registrationCode,
    this.viewMode = PreviewViewMode.phonePortrait,
    this.log,
    this.actions,
    this.logTab = LeftPaneTab.server,
    this.status,
  });

  final PreviewPhase phase;
  final String? errorMessage;
  final ToolsView? tools;
  final ExternalEditorsView? editors;
  final FullRestartView? process;
  final String? registrationCode;
  final PreviewViewMode viewMode;

  /// Defaults to a sample log matching [phase].
  final RunnerLog? log;
  final RunnerActionsView? actions;
  final LeftPaneTab logTab;

  /// Defaults to what a runner would say at [phase].
  final ServerStatus? status;

  ServerStatus get _status => status ?? switch (phase) {
        PreviewPhase.ready => const ServerStatus.running(),
        PreviewPhase.idle => const ServerStatus.stopped('Stopped'),
        PreviewPhase.failed => ServerStatus.stopped(
            'Build failed',
            detail: errorMessage,
          ),
        PreviewPhase.fetchingDependencies =>
          const ServerStatus.busy('Fetching packages'),
        PreviewPhase.startingServerpod =>
          const ServerStatus.busy('Starting Serverpod'),
        PreviewPhase.waitingForServer =>
          const ServerStatus.busy('Compiling server'),
        PreviewPhase.loadingApp => const ServerStatus.busy(
            'Launching Demo app (first run may take 30-60s)',
          ),
        PreviewPhase.connecting => const ServerStatus.busy('Loading the app'),
        PreviewPhase.stopping => const ServerStatus.busy('Stopping the server'),
      };

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    final log = this.log ??
        sampleRunnerLog(
          failure: phase.isError,
          launching: phase != PreviewPhase.ready && !phase.isError,
        );
    final actions = this.actions ??
        FakeRunnerActions(
          canHotRestart: phase == PreviewPhase.ready,
          canMigrate: phase == PreviewPhase.ready || phase.isError,
        );
    return Column(
      children: [
        StudioToolbar(
          status: FakeServerStatus(_status),
          tools: tools ?? FakeToolsView(inventory: completeInventory),
          process: process ?? FakeFullRestart(),
          actions: actions,
          editors: editors ??
              FakeExternalEditors(
                editors: const [cursorEditor, claudeEditor],
                canOpen: phase == PreviewPhase.ready,
              ),
          onManageTools: () {},
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: 560,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    LeftPaneHeader(
                      tabs: leftPaneTabs(log),
                      selected: logTab,
                      onChanged: (_) {},
                    ),
                    Expanded(
                      child: ServerLogView(
                        log: log,
                        view: LogViewController()..tab = logTab,
                        source: switch (logTab) {
                          LogTab(:final source) => source,
                          AgentTab() => const ServerLogSource(),
                        },
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: kDividerWidth,
                child: ColoredBox(color: scheme.border),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PreviewHeaderBar(
                      previewBrightness: Brightness.light,
                      viewMode: viewMode,
                      minimized: false,
                      onPreviewThemeChanged: (_) {},
                      onViewModeChanged: (_) {},
                      onToggleMinimized: () {},
                    ),
                    Expanded(child: _PreviewArea(this)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PreviewArea extends StatelessWidget {
  const _PreviewArea(this.window);

  final StudioWindowMock window;

  @override
  Widget build(BuildContext context) {
    final phase = window.phase;
    return Stack(
      fit: StackFit.expand,
      children: [
        PreviewHeroGradient(
          animating: phase.showsLoadingOverlay,
          child: Center(
            child: phase == PreviewPhase.ready
                ? const _AppPlaceholder()
                : const SizedBox.shrink(),
          ),
        ),
        PreviewStatusOverlay(phase: phase, errorMessage: window.errorMessage),
        if (window.registrationCode case final code?)
          Positioned(
            top: 16,
            right: 16,
            child: RegistrationCodeToast(code: code, onDismiss: () {}),
          ),
      ],
    );
  }
}

/// Where CEF would draw the user's app.
class _AppPlaceholder extends StatelessWidget {
  const _AppPlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Container(
      width: 300,
      height: 600,
      decoration: BoxDecoration(
        color: previewBackdropColor(Brightness.light),
        borderRadius: BorderRadius.circular(36),
        border: Border.all(color: Colors.black, width: 10),
      ),
      alignment: Alignment.center,
      child: Text(
        'The app renders here',
        style: theme.textTheme.muted.copyWith(color: Colors.black54),
      ),
    );
  }
}
