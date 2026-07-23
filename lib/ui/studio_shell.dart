import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:shadcn_ui/shadcn_ui.dart';

import '../process/serverpod_process.dart';
import '../session/project_session.dart';
import '../terminal/studio_terminal.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../toolchain/toolchain.dart';
import '../widgets/menu_item_tile.dart';
import 'preview_pane.dart';
import 'terminal_pane.dart';

class StudioShell extends StatefulWidget {
  const StudioShell({
    super.key,
    required this.toolchain,
    required this.session,
    required this.terminal,
    required this.process,
    required this.themeController,
  });

  final Toolchain toolchain;
  final ProjectSession session;
  final StudioTerminal terminal;
  final ServerpodProcessController process;
  final ThemeController themeController;

  @override
  State<StudioShell> createState() => _StudioShellState();
}

class _StudioShellState extends State<StudioShell> {
  final _previewKey = GlobalKey<PreviewPaneState>();
  double _splitRatio = 0.42;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.session,
        widget.process,
        widget.themeController,
      ]),
      builder: (context, _) {
        final hasProject = widget.session.hasProject;
        return Column(
          children: [
            _Toolbar(
              toolchain: widget.toolchain,
              session: widget.session,
              process: widget.process,
              themeController: widget.themeController,
              onReload: () => _previewKey.currentState?.reload(),
            ),
            Expanded(
              child: hasProject
                  ? _Workspace(
                      splitRatio: _splitRatio,
                      onSplitChanged: (value) {
                        setState(() {
                          _splitRatio = value.clamp(0.25, 0.70);
                        });
                      },
                      terminal: widget.terminal,
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

class _Toolbar extends StatefulWidget {
  const _Toolbar({
    required this.toolchain,
    required this.session,
    required this.process,
    required this.themeController,
    required this.onReload,
  });

  final Toolchain toolchain;
  final ProjectSession session;
  final ServerpodProcessController process;
  final ThemeController themeController;
  final VoidCallback onReload;

  @override
  State<_Toolbar> createState() => _ToolbarState();
}

class _ToolbarState extends State<_Toolbar> {
  final _recentsController = ShadPopoverController();

  @override
  void dispose() {
    _recentsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    final statusColor = switch (widget.process.state) {
      ProcessState.idle => widget.process.previewReady
          ? AppColors.successDot
          : scheme.mutedForeground,
      ProcessState.starting => AppColors.warningAmber,
      ProcessState.running => widget.process.previewReady
          ? AppColors.successDot
          : kBrandBlue,
      ProcessState.stopping => AppColors.warningAmber,
    };

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: scheme.background,
        border: Border(bottom: BorderSide(color: scheme.border)),
      ),
      child: Row(
        children: [
          Text(
            'App Studio',
            style: textTheme.p.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 16),
          _IconAction(
            icon: LucideIcons.folderOpen,
            tooltip: 'Open project',
            onPressed: widget.session.openProjectPicker,
          ),
          _IconAction(
            icon: LucideIcons.play,
            tooltip: 'Start',
            onPressed: widget.process.canStart ? widget.process.start : null,
          ),
          _IconAction(
            icon: LucideIcons.square,
            tooltip: 'Stop',
            onPressed: widget.process.canStop ? widget.process.stop : null,
          ),
          _IconAction(
            icon: LucideIcons.refreshCw,
            tooltip: 'Reload preview',
            onPressed: widget.process.previewReady ? widget.onReload : null,
          ),
          if (widget.session.recents.isNotEmpty) ...[
            const SizedBox(width: 4),
            ShadPopover(
              controller: _recentsController,
              anchor: const ShadAnchor(
                childAlignment: Alignment.topLeft,
                overlayAlignment: Alignment.bottomLeft,
                offset: Offset(0, 4),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              popover: (context) => SizedBox(
                width: 360,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final path in widget.session.recents)
                      MenuItemTile(
                        icon: LucideIcons.folder,
                        label: p.basename(path),
                        subtitle: path,
                        onTap: () {
                          _recentsController.hide();
                          widget.session.openPath(path);
                        },
                      ),
                  ],
                ),
              ),
              child: ShadTooltip(
                builder: (context) => const Text('Recent projects'),
                child: ShadIconButton.ghost(
                  icon: const Icon(LucideIcons.history, size: 16),
                  onPressed: _recentsController.toggle,
                  width: 34,
                  height: 34,
                ),
              ),
            ),
          ],
          const SizedBox(width: 12),
          if (widget.session.hasProject)
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      widget.session.projectName ?? '',
                      style: textTheme.small.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      widget.session.projectPath ?? '',
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
                  widget.toolchain.badgeLabel,
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
                  widget.process.statusMessage,
                  style: textTheme.small.copyWith(
                    color: scheme.mutedForeground,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          _IconAction(
            icon: switch (widget.themeController.mode) {
              ThemeMode.light => LucideIcons.sun,
              ThemeMode.dark => LucideIcons.moon,
              ThemeMode.system => LucideIcons.monitor,
            },
            tooltip: 'Theme: ${widget.themeController.label}',
            onPressed: widget.themeController.cycle,
          ),
        ],
      ),
    );
  }
}

class _Workspace extends StatelessWidget {
  const _Workspace({
    required this.splitRatio,
    required this.onSplitChanged,
    required this.terminal,
    required this.previewKey,
    required this.previewUrl,
    required this.shouldLoad,
    required this.reloadToken,
  });

  final double splitRatio;
  final ValueChanged<double> onSplitChanged;
  final StudioTerminal terminal;
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
        final left = total * splitRatio;

        return Row(
          children: [
            SizedBox(
              width: left,
              child: TerminalPane(studioTerminal: terminal),
            ),
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) {
                  onSplitChanged((left + details.delta.dx) / total);
                },
                child: Container(
                  width: 5,
                  color: scheme.border,
                ),
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
