import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../agent/agent_controller.dart';
import '../mcp/mcp_controller.dart';
import '../preview/preview_mode_controller.dart';
import '../preview/preview_phase.dart';
import '../process/serverpod_process.dart';
import '../session/external_editors_view.dart';
import '../session/project_session.dart';
import '../terminal/studio_terminal.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../toolchain/toolchain_controller.dart';
import 'new_project_dialog.dart';
import 'preview_pane.dart';
import 'settings/settings_dialog.dart';
import 'start_page.dart';
import 'studio_toolbar.dart';
import 'terminal_pane.dart';

class StudioShell extends StatefulWidget {
  const StudioShell({
    super.key,
    required this.toolchains,
    required this.session,
    required this.terminal,
    required this.process,
    required this.agent,
    required this.mcp,
    required this.editors,
    required this.themeController,
    required this.previewMode,
  });

  final ToolchainController toolchains;
  final ProjectSession session;
  final StudioTerminal terminal;
  final ServerpodProcessController process;
  final AgentController agent;
  final McpController mcp;
  final ExternalEditorsView editors;
  final ThemeController themeController;
  final PreviewModeController previewMode;

  @override
  State<StudioShell> createState() => _StudioShellState();
}

class _StudioShellState extends State<StudioShell> {
  final _previewKey = GlobalKey<PreviewPaneState>();
  double _splitRatio = 0.42;
  bool _leftPanelVisible = true;

  @override
  void initState() {
    super.initState();
    widget.agent.setOpenSettingsHandler(_openSettings);
  }

  @override
  void dispose() {
    widget.agent.setOpenSettingsHandler(null);
    super.dispose();
  }

  void _openSettings() => unawaited(_showSettings(SettingsTab.providers));

  void _openManageTools() => unawaited(_showSettings(SettingsTab.tools));

  /// Settings is the one place the agent is worth having up without a project:
  /// it is where keys and the default model are configured, and both are read
  /// from the running agent. With a project open this is a no-op — that agent
  /// is already the real one, and closing Settings leaves it alone.
  ///
  /// Does nothing while the toolchain still needs first-run setup. The App menu
  /// greys the item out on the same condition, and this shell is not even built
  /// in that state, so this is the belt to that pair of braces: every route in
  /// goes through here — the menu item, `AgentController`'s handler and the
  /// toolbar's warning badge — and the one thing Settings could offer then is a
  /// Tools tab duplicating the setup screen already on top of it.
  Future<void> _showSettings(SettingsTab tab) async {
    if (widget.toolchains.inventory.needsSetup) return;
    unawaited(widget.agent.startForSettings());
    try {
      await showSettingsDialog(
        context,
        agent: widget.agent,
        toolchains: widget.toolchains,
        initialTab: tab,
      );
    } finally {
      await widget.agent.stopIfStartedForSettings();
    }
  }

  void _newProject() {
    showNewProjectScreen(
      context,
      toolchains: widget.toolchains,
      session: widget.session,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.session,
        widget.process,
        widget.themeController,
        widget.agent,
        widget.previewMode,
      ]),
      builder: (context, _) {
        final hasProject = widget.session.hasProject;
        if (!hasProject) {
          return StartPage(session: widget.session, onNewProject: _newProject);
        }

        // Minimized phone preview: the window is the frame. Nothing but the
        // preview pane may build here — everything else would paint onto a
        // transparent window. The pane keeps its GlobalKey, so the CEF webview
        // survives the re-parent instead of reloading.
        if (widget.previewMode.compactWindow) {
          return PreviewPane(
            key: _previewKey,
            previewUrl: ProjectSession.previewUri,
            process: widget.process,
            mode: widget.previewMode,
          );
        }

        return Column(
          children: [
            // Minimized desktop preview keeps the whole workspace and only
            // drops the toolbar.
            if (!widget.previewMode.minimized)
              StudioToolbar(
                projectName: widget.session.projectName,
                projectPath: widget.session.projectPath,
                tools: widget.toolchains,
                onManageTools: _openManageTools,
                process: widget.process,
                mcp: widget.mcp,
                editors: widget.editors,
                onToggleLeftPanel: () {
                  setState(() {
                    _leftPanelVisible = !_leftPanelVisible;
                  });
                },
              ),
            Expanded(
              child: _Workspace(
                splitRatio: _splitRatio,
                // Minimized is preview-only in every view mode: desktop keeps
                // the workspace but the server log goes with the toolbar. The
                // user's own toggle is preserved for the way back.
                leftPanelVisible:
                    _leftPanelVisible && !widget.previewMode.minimized,
                onSplitChanged: (value) {
                  setState(() {
                    _splitRatio = value.clamp(
                      kWorkspaceMinSplitRatio,
                      kWorkspaceMaxSplitRatio,
                    );
                  });
                },
                terminal: widget.terminal,
                agent: widget.agent,
                previewKey: _previewKey,
                previewUrl: ProjectSession.previewUri,
                process: widget.process,
                previewMode: widget.previewMode,
                gradientAnimating: widget.process.phase.showsLoadingOverlay,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Workspace extends StatelessWidget {
  const _Workspace({
    required this.splitRatio,
    required this.leftPanelVisible,
    required this.onSplitChanged,
    required this.terminal,
    required this.agent,
    required this.previewKey,
    required this.previewUrl,
    required this.process,
    required this.previewMode,
    required this.gradientAnimating,
  });

  final double splitRatio;
  final bool leftPanelVisible;
  final ValueChanged<double> onSplitChanged;
  final StudioTerminal terminal;
  final AgentController agent;
  final GlobalKey<PreviewPaneState> previewKey;
  final Uri previewUrl;
  final ServerpodProcessController process;
  final PreviewModeController previewMode;
  final bool gradientAnimating;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final total = constraints.maxWidth;
        // The stored split is a ratio, but the floor is pixels: the panel
        // never drops below an 80-column log line, which a ratio minimum
        // cannot promise — it thins out with the window. The max ratio still
        // caps it, and wins when the window is too narrow for both.
        final maxLeft = total * kWorkspaceMaxSplitRatio;
        final minLeft = math.min(terminalPaneMinWidth(), maxLeft);
        final left = leftPanelVisible
            ? clampDouble(total * splitRatio, minLeft, maxLeft)
            : 0.0;

        return Stack(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (leftPanelVisible)
                  SizedBox(
                    width: left,
                    child: TerminalPane(
                      studioTerminal: terminal,
                      agent: agent,
                      process: process,
                    ),
                  ),
                Expanded(
                  child: PreviewPane(
                    key: previewKey,
                    previewUrl: previewUrl,
                    process: process,
                    mode: previewMode,
                    gradientAnimating: gradientAnimating,
                  ),
                ),
              ],
            ),
            if (leftPanelVisible) ...[
              Positioned(
                left: left - kDividerWidth / 2,
                top: 0,
                bottom: 0,
                width: kDividerWidth,
                child: ColoredBox(color: scheme.border),
              ),
              Positioned(
                left: left - kSplitHandleWidth / 2,
                top: 0,
                bottom: 0,
                width: kSplitHandleWidth,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeColumn,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragUpdate: (details) {
                      onSplitChanged((left + details.delta.dx) / total);
                    },
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
