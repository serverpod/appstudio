import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart';

import '../agent/agent_controller.dart';
import '../process/serverpod_process.dart';
import '../session/project_session.dart';
import '../terminal/studio_terminal.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../toolchain/toolchain.dart';
import '../widgets/menu_item_tile.dart';
import 'preview_pane.dart';
import 'settings/providers_settings_dialog.dart';
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
        return Column(
          children: [
            _Toolbar(
              toolchain: widget.toolchain,
              session: widget.session,
              process: widget.process,
              leftPanelVisible: _leftPanelVisible,
              onToggleLeftPanel: widget.session.hasProject
                  ? () {
                      setState(() {
                        _leftPanelVisible = !_leftPanelVisible;
                      });
                    }
                  : null,
              onReload: () => _previewKey.currentState?.reload(),
            ),
            Expanded(
              child: hasProject
                  ? _Workspace(
                      splitRatio: _splitRatio,
                      leftPanelVisible: _leftPanelVisible,
                      onSplitChanged: (value) {
                        setState(() {
                          _splitRatio = value.clamp(0.25, 0.70);
                        });
                      },
                      terminal: widget.terminal,
                      agent: widget.agent,
                      onOpenSettings: _openSettings,
                      previewKey: _previewKey,
                      previewUrl: ProjectSession.previewUri,
                      shouldLoad: widget.process.previewReady,
                      reloadToken: widget.process.previewReloadToken,
                    )
                  : _EmptyState(session: widget.session),
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
    required this.onReload,
  });

  final Toolchain toolchain;
  final ProjectSession session;
  final ServerpodProcessController process;
  final bool leftPanelVisible;
  final VoidCallback? onToggleLeftPanel;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    final statusColor = switch (process.state) {
      ProcessState.idle => process.previewReady
          ? AppColors.successDot
          : scheme.mutedForeground,
      ProcessState.starting => AppColors.warningAmber,
      ProcessState.running => process.previewReady
          ? AppColors.successDot
          : kBrandBlue,
      ProcessState.stopping => AppColors.warningAmber,
    };

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
          const SizedBox(width: 4),
          _IconAction(
            icon: LucideIcons.play,
            tooltip: 'Start',
            onPressed: process.canStart ? process.start : null,
          ),
          _IconAction(
            icon: LucideIcons.square,
            tooltip: 'Stop',
            onPressed: process.canStop ? process.stop : null,
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
          const SizedBox(width: 8),
          ShadBadge.outline(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  process.statusMessage,
                  style: textTheme.small.copyWith(
                    color: scheme.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          _IconAction(
            icon: LucideIcons.refreshCw,
            tooltip: 'Reload preview',
            onPressed: process.previewReady ? onReload : null,
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
    required this.onOpenSettings,
    required this.previewKey,
    required this.previewUrl,
    required this.shouldLoad,
    required this.reloadToken,
  });

  final double splitRatio;
  final bool leftPanelVisible;
  final ValueChanged<double> onSplitChanged;
  final StudioTerminal terminal;
  final AgentController agent;
  final VoidCallback onOpenSettings;
  final GlobalKey<PreviewPaneState> previewKey;
  final Uri previewUrl;
  final bool shouldLoad;
  final int reloadToken;

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
                      onOpenSettings: onOpenSettings,
                    ),
                  ),
                Expanded(
                  child: PreviewPane(
                    key: previewKey,
                    previewUrl: previewUrl,
                    shouldLoad: shouldLoad,
                    reloadToken: reloadToken,
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

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.session});

  final ProjectSession session;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final isDark = theme.brightness == Brightness.dark;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(LucideIcons.boxes, size: 40, color: scheme.primary),
              const SizedBox(height: 16),
              Text(
                'App Studio',
                style: textTheme.h3.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                'Open a Serverpod project to get started',
                textAlign: TextAlign.center,
                style: textTheme.muted,
              ),
              if (session.error != null) ...[
                const SizedBox(height: 12),
                Text(
                  session.error!,
                  textAlign: TextAlign.center,
                  style: textTheme.small.copyWith(
                    color: isDark
                        ? AppColors.errorTextDark
                        : AppColors.errorText,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              ShadButton(
                onPressed: session.openProjectPicker,
                size: ShadButtonSize.sm,
                leading: const Icon(LucideIcons.folderOpen, size: 16),
                child: const Text('Open project'),
              ),
              if (session.recents.isNotEmpty) ...[
                const SizedBox(height: 32),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Recent',
                    style: textTheme.small.copyWith(
                      fontWeight: FontWeight.w500,
                      color: scheme.mutedForeground,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Container(
                  decoration: BoxDecoration(
                    borderRadius: theme.radius,
                    border: Border.all(color: scheme.border),
                    color: scheme.card,
                  ),
                  child: Column(
                    children: [
                      for (var i = 0; i < session.recents.length; i++) ...[
                        if (i > 0)
                          Divider(height: 1, color: scheme.border),
                        MenuItemTile(
                          icon: LucideIcons.folder,
                          label: p.basename(session.recents[i]),
                          subtitle: session.recents[i],
                          onTap: () => session.openPath(session.recents[i]),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
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
