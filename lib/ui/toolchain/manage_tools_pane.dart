import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../theme/app_theme.dart';
import '../../toolchain/install_progress.dart';
import '../../toolchain/tool_status.dart';
import '../../widgets/command_block.dart';
import '../../widgets/determinate_progress.dart';
import '../../widgets/error_banner.dart';
import '../../widgets/settings_table.dart';
import 'toolchain_notices.dart';
import 'toolchain_setup_dialog.dart' show installCaption;
import 'tools_view.dart';

/// Which tools are in play, which version, and who installed them.
///
/// A pane inside the Settings dialog, so it owns no chrome of its own — the
/// install button lives in the dialog's footer.
///
/// Deliberately the same table first-run setup shows, so the same toolchain
/// never looks like two different things depending on which screen you reached
/// it from.
class ManageToolsPane extends StatefulWidget {
  const ManageToolsPane({super.key, required this.toolchains});

  final ToolsView toolchains;

  @override
  State<ManageToolsPane> createState() => _ManageToolsPaneState();
}

class _ManageToolsPaneState extends State<ManageToolsPane> {
  @override
  void initState() {
    super.initState();
    widget.toolchains.addListener(_onToolchains);
    // Deferred to after the frame: refresh() notifies synchronously before its
    // first await, so starting it here marks any ancestor listening to the
    // controller dirty in the middle of its own build.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // The startup probe stops at the first satisfied candidate; this view
      // wants the alternatives too.
      await widget.toolchains.refreshDeep();
      // Versions for anything the footer's Install button would act on.
      if (mounted && widget.toolchains.inventory.installable.isNotEmpty) {
        unawaited(widget.toolchains.preflight());
      }
    });
  }

  @override
  void dispose() {
    widget.toolchains.removeListener(_onToolchains);
    super.dispose();
  }

  void _onToolchains() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final toolchains = widget.toolchains;
    final inventory = toolchains.inventory;
    final missing = inventory.missingRequired;
    final manual = inventory.needsManualUpdate;
    final pathLines = toolchains.manualPathLines;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'App Studio uses these tools to create and run Serverpod projects.',
            style: theme.textTheme.muted,
          ),
          const ShadGap(3),
          if (toolchains.installError case final error?) ...[
            ErrorBanner(message: error),
            const ShadGap(3),
          ] else if (missing.isNotEmpty &&
              manual.isEmpty &&
              !toolchains.isInstalling) ...[
            ErrorBanner(message: _missingMessage(missing)),
            const ShadGap(3),
          ],
          if (toolchains.progress case final progress?
              when toolchains.isInstalling) ...[
            _InstallBanner(
              progress: progress,
              onCancel: toolchains.cancelInstall,
            ),
            const ShadGap(3),
          ],
          SettingsTable(
            rows: [
              for (final id in ToolId.values)
                if (inventory[id] case final status?) _rowFor(theme, status),
            ],
          ),
          for (final status in manual) ...[
            const ShadGap(3),
            ErrorBanner(message: manualUpdateMessage(status)),
            if (status.bestRejected case final candidate?
                when candidate.fitness == ToolFitness.wrongVersion) ...[
              const ShadGap(2),
              CommandBlock(command: manualUpdateCommand(candidate)),
            ],
          ],
          if (pathLines.isNotEmpty) ...[
            const ShadGap(3),
            Text(
              'Add to your shell configuration',
              style: theme.textTheme.small.semibold,
            ),
            const ShadGap(1),
            Text(
              'App Studio cannot edit this shell\'s configuration. Add these '
              'lines yourself so your terminal and external AI agents can '
              'find the tools:',
              style: theme.textTheme.muted,
            ),
            const ShadGap(2),
            CommandBlock(command: pathLines.join('\n')),
          ],
        ],
      ),
    );
  }

  /// The version in play, then what it means: who installed a usable copy, or
  /// what it would take to get one.
  SettingsTableRow _rowFor(ShadThemeData theme, ToolStatus status) {
    final resolved = status.resolved;
    final planned = widget.toolchains.plan[status.id]?.version;
    final rejected = status.bestRejected?.detectedVersion;
    final version = resolved?.detectedVersion ?? planned ?? rejected;

    return SettingsTableRow(
      name: status.spec.displayName,
      badge: version == null
          ? null
          : versionBadge(
              version,
              replacing: resolved == null && planned != null ? rejected : null,
            ),
      trailing: switch (resolved) {
        // `success`/`warning` ride in the scheme's custom map; there is no
        // shadcn token for either.
        final r? => appSuccessBadge(theme, child: Text(r.source.label)),
        null => appWarningBadge(
            theme,
            child: Text(switch (status.action) {
              ToolAction.manual || ToolAction.update => 'Update needed',
              _ => 'Missing',
            }),
          ),
      },
    );
  }

  String _missingMessage(List<ToolStatus> missing) => missing.length == 1
      ? '${missing.single.spec.displayName} is missing. Some features will '
            'not work until it is installed.'
      : '${missing.length} tools are missing. Some features will not work '
            'until they are installed.';
}

class _InstallBanner extends StatelessWidget {
  const _InstallBanner({required this.progress, required this.onCancel});

  final InstallProgress progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;

    return ShadCard(
      backgroundColor: scheme.muted,
      title: Text(progress.statusLabel),
      // A card title defaults to `h3`, which is a headline role and so is set
      // in Inter Black — far too loud for a progress banner inside a pane.
      // This one is a label for the bar underneath it.
      titleStyle: theme.textTheme.large,
      action: ShadButton.ghost(
        enabled: !progress.isDone,
        onPressed: progress.isDone ? null : onCancel,
        child: const Text('Cancel'),
      ),
      child: DeterminateProgress(
        fraction: progress.fraction,
        caption: installCaption(progress),
      ),
    );
  }
}
