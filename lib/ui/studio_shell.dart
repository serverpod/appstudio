import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../agent/agent_controller.dart';
import '../preview/preview_phase.dart';
import '../process/serverpod_process.dart';
import '../session/project_session.dart';
import '../terminal/studio_terminal.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../toolchain/toolchain.dart';
import 'preview_pane.dart';
import 'settings/providers_settings_dialog.dart';
import 'start_page.dart';
import 'terminal_pane.dart';

class StudioShell extends StatefulWidget {
  const StudioShell({
    super.key,
    required this.toolchain,
    required this.session,
    required this.terminal,
    required this.process,
    required this.agent,
    required this.themeController,
  });

  final Toolchain toolchain;
  final ProjectSession session;
  final StudioTerminal terminal;
  final ServerpodProcessController process;
  final AgentController agent;
  final ThemeController themeController;

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

  void _openSettings() {
    showProvidersSettingsDialog(context, agent: widget.agent);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.session,
        widget.process,
        widget.themeController,
        widget.agent,
      ]),
      builder: (context, _) {
        final hasProject = widget.session.hasProject;
        if (!hasProject) {
          return StartPage(session: widget.session);
        }

        return Column(
          children: [
            _Toolbar(
              toolchain: widget.toolchain,
              session: widget.session,
              process: widget.process,
              leftPanelVisible: _leftPanelVisible,
              onToggleLeftPanel: () {
                setState(() {
                  _leftPanelVisible = !_leftPanelVisible;
                });
              },
            ),
            Expanded(
              child: _Workspace(
                splitRatio: _splitRatio,
                leftPanelVisible: _leftPanelVisible,
                onSplitChanged: (value) {
                  setState(() {
                    _splitRatio = value.clamp(0.25, 0.70);
                  });
                },
                terminal: widget.terminal,
                agent: widget.agent,
                previewKey: _previewKey,
                previewUrl: ProjectSession.previewUri,
                process: widget.process,
                gradientAnimating: widget.process.phase.showsLoadingOverlay,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.toolchain,
    required this.session,
    required this.process,
    required this.leftPanelVisible,
    required this.onToggleLeftPanel,
  });

  final Toolchain toolchain;
  final ProjectSession session;
  final ServerpodProcessController process;
  final bool leftPanelVisible;
  final VoidCallback? onToggleLeftPanel;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: scheme.background,
        border: Border(bottom: paneBorderSide(scheme.border)),
      ),
      child: Row(
        children: [
          _IconAction(
            icon: LucideIcons.panelLeft,
            tooltip: leftPanelVisible
                ? 'Hide Agent & logs panel'
                : 'Show Agent & logs panel',
            onPressed: onToggleLeftPanel,
          ),
          const SizedBox(width: 12),
          if (session.hasProject)
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      session.projectName ?? '',
                      style: textTheme.small.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      session.projectPath ?? '',
                      style: textTheme.muted.copyWith(
                        fontFamily: kMacMonoFont,
                        fontSize: 11,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            )
          else
            const Spacer(),
          ShadBadge.secondary(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.package,
                  size: 12,
                  color: scheme.mutedForeground,
                ),
                const SizedBox(width: 6),
                Text(
                  toolchain.badgeLabel,
                  style: textTheme.small.copyWith(
                    fontWeight: FontWeight.w500,
                    color: scheme.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          _IconAction(
            icon: LucideIcons.play,
            tooltip: 'Start',
            onPressed: session.hasProject && process.canStart
                ? process.start
                : null,
          ),
          _IconAction(
            icon: LucideIcons.square,
            tooltip: 'Stop',
            onPressed: session.hasProject && process.canStop
                ? process.stop
                : null,
          ),
        ],
      ),
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
  final bool gradientAnimating;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final total = constraints.maxWidth;
        final left = leftPanelVisible ? total * splitRatio : 0.0;

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

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return ShadTooltip(
      builder: (context) => Text(tooltip),
      child: ShadIconButton.ghost(
        icon: Icon(icon, size: 16),
        onPressed: onPressed,
        width: 34,
        height: 34,
      ),
    );
  }
}
