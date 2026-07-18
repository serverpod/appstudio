import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../process/serverpod_process.dart';
import '../session/project_session.dart';
import '../terminal/studio_terminal.dart';
import '../theme/app_theme.dart';
import '../theme/theme_controller.dart';
import '../toolchain/toolchain.dart';
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
                      previewBrightness: _previewBrightness(context),
                    )
                  : _EmptyState(session: widget.session),
            ),
          ],
        );
      },
    );
  }

  Brightness _previewBrightness(BuildContext context) {
    return switch (widget.themeController.mode) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      ThemeMode.system => MediaQuery.platformBrightnessOf(context),
    };
  }
}

class _Toolbar extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    final statusColor = switch (process.state) {
      ProcessState.idle =>
        process.previewReady ? colors.statusReady : colors.statusIdle,
      ProcessState.starting => colors.statusStarting,
      ProcessState.running =>
        process.previewReady ? colors.statusReady : colors.statusRunning,
      ProcessState.stopping => colors.statusStarting,
    };

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: colors.toolbarBackground,
        border: Border(bottom: BorderSide(color: colors.divider)),
      ),
      child: Row(
        children: [
          Text(
            'App Studio',
            style: GoogleFonts.ibmPlexSans(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(width: 16),
          _IconAction(
            icon: LucideIcons.folderOpen,
            tooltip: 'Open project',
            onPressed: session.openProjectPicker,
          ),
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
          _IconAction(
            icon: LucideIcons.refreshCw,
            tooltip: 'Reload preview',
            onPressed: process.previewReady ? onReload : null,
          ),
          if (session.recents.isNotEmpty) ...[
            const SizedBox(width: 4),
            PopupMenuButton<String>(
              tooltip: 'Recent projects',
              padding: EdgeInsets.zero,
              onSelected: session.openPath,
              itemBuilder: (context) => [
                for (final path in session.recents)
                  PopupMenuItem(
                    value: path,
                    child: Text(
                      path,
                      style: GoogleFonts.ibmPlexMono(fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Icon(
                  LucideIcons.history,
                  size: 16,
                  color: Theme.of(context).iconTheme.color,
                ),
              ),
            ),
          ],
          const SizedBox(width: 12),
          if (session.hasProject)
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      session.projectName ?? '',
                      style: GoogleFonts.ibmPlexSans(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      session.projectPath ?? '',
                      style: GoogleFonts.ibmPlexMono(
                        fontSize: 11,
                        color: colors.emptyStateMuted,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            )
          else
            const Spacer(),
          _Badge(label: toolchain.badgeLabel),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: colors.divider),
              borderRadius: BorderRadius.circular(6),
            ),
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
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 11,
                    color: colors.emptyStateMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          _IconAction(
            icon: switch (themeController.mode) {
              ThemeMode.light => LucideIcons.sun,
              ThemeMode.dark => LucideIcons.moon,
              ThemeMode.system => LucideIcons.monitor,
            },
            tooltip: 'Theme: ${themeController.label}',
            onPressed: themeController.cycle,
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
    required this.previewBrightness,
  });

  final double splitRatio;
  final ValueChanged<double> onSplitChanged;
  final StudioTerminal terminal;
  final GlobalKey<PreviewPaneState> previewKey;
  final Uri previewUrl;
  final bool shouldLoad;
  final int reloadToken;
  final Brightness previewBrightness;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;

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
                  color: colors.divider,
                ),
              ),
            ),
            Expanded(
              child: PreviewPane(
                key: previewKey,
                previewUrl: previewUrl,
                shouldLoad: shouldLoad,
                reloadToken: reloadToken,
                previewBrightness: previewBrightness,
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
    final colors = Theme.of(context).extension<AppColors>()!;
    final scheme = Theme.of(context).colorScheme;

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
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.6,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Open a Serverpod project to get started',
                textAlign: TextAlign.center,
                style: GoogleFonts.ibmPlexSans(
                  fontSize: 14,
                  color: colors.emptyStateMuted,
                ),
              ),
              if (session.error != null) ...[
                const SizedBox(height: 12),
                Text(
                  session.error!,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.ibmPlexSans(
                    fontSize: 12,
                    color: colors.statusDanger,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: session.openProjectPicker,
                icon: const Icon(LucideIcons.folderOpen, size: 16),
                label: const Text('Open project'),
              ),
              if (session.recents.isNotEmpty) ...[
                const SizedBox(height: 32),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Recent',
                    style: GoogleFonts.ibmPlexSans(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: colors.emptyStateMuted,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                for (final path in session.recents)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      LucideIcons.folder,
                      size: 16,
                      color: colors.emptyStateMuted,
                    ),
                    title: Text(
                      p.basename(path),
                      style: GoogleFonts.ibmPlexSans(fontSize: 13),
                    ),
                    subtitle: Text(
                      path,
                      style: GoogleFonts.ibmPlexMono(
                        fontSize: 11,
                        color: colors.emptyStateMuted,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => session.openPath(path),
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
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: colors.badgeBackground,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.package, size: 12, color: colors.badgeForeground),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.ibmPlexSans(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: colors.badgeForeground,
            ),
          ),
        ],
      ),
    );
  }
}
