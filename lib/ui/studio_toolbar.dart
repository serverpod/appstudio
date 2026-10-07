import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../process/full_restart_view.dart';
import '../runner/runner_actions_view.dart';
import '../session/external_editors_view.dart';
import '../theme/app_theme.dart';
import 'full_restart_button.dart';
import 'hot_reload_buttons.dart';
import 'open_in_editor_buttons.dart';
import 'publish_to_cloud_button.dart';
import 'toolchain/tools_view.dart';

/// The bar across the top of an open project: the panel toggle, the project's
/// name and path, then everything that acts on the project.
///
/// Built from narrow views rather than the controllers, so it can be drawn in
/// Widgetbook with every button in every state.
class StudioToolbar extends StatelessWidget {
  const StudioToolbar({
    super.key,
    required this.projectName,
    required this.projectPath,
    required this.tools,
    required this.process,
    required this.actions,
    required this.editors,
    required this.onToggleLeftPanel,
    required this.onManageTools,
  });

  /// Null with no project open, which leaves the middle of the bar empty.
  final String? projectName;
  final String? projectPath;
  final ToolsView tools;
  final FullRestartView process;
  final RunnerActionsView actions;
  final ExternalEditorsView editors;
  final VoidCallback? onToggleLeftPanel;
  final VoidCallback onManageTools;

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
            onPressed: onToggleLeftPanel,
          ),
          const SizedBox(width: 12),
          if (projectName != null)
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      projectName ?? '',
                      style: textTheme.small.medium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      projectPath ?? '',
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
          ToolchainWarningBadge(tools: tools, onTap: onManageTools),
          OpenInEditorButtons(editors: editors),
          const PublishToCloudButton(),
          const SizedBox(width: 8),
          HotReloadButton(actions: actions),
          const SizedBox(width: 8),
          HotRestartButton(actions: actions),
          const SizedBox(width: 8),
          FullRestartButton(process: process),
        ],
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.onPressed,
  });

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return ShadIconButton.ghost(
      icon: Icon(icon, size: 16),
      // A null handler alone leaves the button inert but undimmed, which
      // reads as a broken click rather than an unavailable action.
      enabled: onPressed != null,
      onPressed: onPressed,
      width: kToolbarIconButtonSize,
      height: kToolbarIconButtonSize,
    );
  }
}

/// Destructive toolbar badge for a required tool that could not be resolved,
/// opening the Tools Manager.
///
/// Nothing is drawn while the toolchain is complete. It used to sit there
/// permanently reading "managed 3.35.0" — a version the user cannot act on, in
/// the spot the Open in … buttons now occupy. The warning half stays: a
/// required tool we cannot supply never reaches the first-run setup screen, so
/// this badge is the only place it surfaces.
class ToolchainWarningBadge extends StatelessWidget {
  const ToolchainWarningBadge({
    super.key,
    required this.tools,
    required this.onTap,
  });

  final ToolsView tools;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: tools,
      builder: (context, _) {
        final theme = ShadTheme.of(context);
        final scheme = theme.colorScheme;
        final missing = tools.inventory.missingRequired.length;
        if (missing == 0) return const SizedBox.shrink();
        final color = scheme.destructive;

        return Padding(
          padding: const EdgeInsets.only(right: 10),
          child: ShadTooltip(
            builder: (context) => const Text(
              'Some tools are missing — open Settings \u2192 Tools',
            ),
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: onTap,
                child: ShadBadge.secondary(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(LucideIcons.circleAlert, size: 12, color: color),
                      const SizedBox(width: 6),
                      Text(
                        '$missing missing',
                        style: theme.textTheme.small
                            .copyWith(color: color)
                            .medium,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
