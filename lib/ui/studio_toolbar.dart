import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../process/full_restart_view.dart';
import '../runner/runner_actions_view.dart';
import '../runner/server_status.dart';
import '../session/external_editors_view.dart';
import '../theme/app_theme.dart';
import 'full_restart_button.dart';
import 'hot_restart_button.dart';
import 'open_in_editor_buttons.dart';
import 'publish_to_cloud_button.dart';
import 'server_status_indicator.dart';
import 'toolchain/tools_view.dart';

/// The bar across the top of an open project: the server's status, then
/// everything that acts on the project.
///
/// The panel toggle that used to lead it is the Logs menu's Show/Hide Logs
/// now, and the project's name and path gave way to the status — what a user
/// needs to see here is whether the server is up, and what it is doing if not.
///
/// Built from narrow views rather than the controllers, so it can be drawn in
/// Widgetbook with every button in every state.
class StudioToolbar extends StatelessWidget {
  const StudioToolbar({
    super.key,
    required this.status,
    required this.tools,
    required this.process,
    required this.actions,
    required this.editors,
    required this.onManageTools,
  });

  final ServerStatusView status;
  final ToolsView tools;
  final FullRestartView process;
  final RunnerActionsView actions;
  final ExternalEditorsView editors;
  final VoidCallback onManageTools;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: scheme.background,
        border: Border(bottom: paneBorderSide(scheme.border)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 4),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: ServerStatusIndicator(status: status),
            ),
          ),
          const SizedBox(width: 12),
          ToolchainWarningBadge(tools: tools, onTap: onManageTools),
          OpenInEditorButtons(editors: editors),
          const PublishToCloudButton(),
          const SizedBox(width: 8),
          HotRestartButton(actions: actions),
          const SizedBox(width: 8),
          FullRestartButton(process: process),
        ],
      ),
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
