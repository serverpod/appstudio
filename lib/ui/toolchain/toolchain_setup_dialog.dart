import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shad/shad.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../theme/app_theme.dart';
import '../../toolchain/install_progress.dart';
import '../../toolchain/tool_status.dart';
import 'tools_view.dart';
import '../../util/byte_format.dart';
import '../../widgets/determinate_progress.dart';
import '../../widgets/error_banner.dart';

const _kDialogWidth = 520.0;

/// Remembers a "Not now" per manifest, so a new pin re-asks.
const _kDismissedKey = 'toolchain.dismissed_manifest';

/// Shows the setup dialog if anything required is missing and installable, and
/// the user has not already declined *this* manifest.
Future<void> maybeShowToolchainSetup(
  BuildContext context, {
  required ToolsView toolchains,
}) async {
  if (toolchains.inventory.installable.isEmpty) return;

  final prefs = await SharedPreferences.getInstance();
  if (prefs.getString(_kDismissedKey) == toolchains.manifestId) {
    return;
  }
  if (!context.mounted) return;

  await showShadDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => ToolchainSetupDialog(toolchains: toolchains),
  );
}

/// First-run preflight: exactly what will be downloaded, and how big it is.
class ToolchainSetupDialog extends StatefulWidget {
  const ToolchainSetupDialog({super.key, required this.toolchains});

  final ToolsView toolchains;

  @override
  State<ToolchainSetupDialog> createState() => _ToolchainSetupDialogState();
}

class _ToolchainSetupDialogState extends State<ToolchainSetupDialog> {
  @override
  void initState() {
    super.initState();
    widget.toolchains.addListener(_onToolchains);
  }

  @override
  void dispose() {
    widget.toolchains.removeListener(_onToolchains);
    super.dispose();
  }

  void _onToolchains() {
    if (!mounted) return;
    setState(() {});
    // Close once everything required is in place.
    final toolchains = widget.toolchains;
    if (!toolchains.isInstalling &&
        toolchains.progress != null &&
        toolchains.inventory.installable.isEmpty &&
        toolchains.installError == null) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _notNow() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kDismissedKey,
      widget.toolchains.manifestId,
    );
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final toolchains = widget.toolchains;
    final inventory = toolchains.inventory;
    final installing = toolchains.isInstalling;
    final reused = [
      for (final status in inventory.tools.values)
        if (status.resolved case final r? when r.source == ToolSource.host)
          status,
    ];

    return PopScope(
      canPop: !installing,
      child: ShadDialog(
        title: const Text('Set up the toolchain'),
        description: const Text(
          'App Studio needs these tools to create and run Serverpod projects. '
          'They install into your home folder and can be removed at any time.',
        ),
        closeIcon: installing ? const SizedBox.shrink() : null,
        actions: installing
            ? [
                ShadButton.outline(
                  onPressed: toolchains.cancelInstall,
                  child: const Text('Cancel'),
                ),
              ]
            : [
                ShadButton.outline(
                  onPressed: _notNow,
                  child: const Text('Not now'),
                ),
                ShadButton(
                  onPressed: toolchains.installMissing,
                  child: const Text('Download'),
                ),
              ],
        child: SizedBox(
          width: _kDialogWidth,
          child: installing
              ? _buildProgress(theme)
              : _buildPlan(theme, reused),
        ),
      ),
    );
  }

  Widget _buildPlan(ShadThemeData theme, List<ToolStatus> reused) {
    final toolchains = widget.toolchains;
    final inventory = toolchains.inventory;
    final scheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (toolchains.installError case final error?) ...[
          ErrorBanner(message: error),
          const SizedBox(height: 12),
        ],
        for (final status in inventory.installable)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${status.spec.displayName} ${status.spec.version}',
                    style: theme.textTheme.small,
                  ),
                ),
                Text(
                  formatBytes(
                    status.spec.artifactForCurrentPlatform!.downloadBytes,
                  ),
                  style: theme.textTheme.muted.copyWith(fontSize: 11),
                ),
              ],
            ),
          ),
        // Reassure that an existing install is being reused, not duplicated.
        for (final status in reused)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              '${status.spec.displayName} '
              '${status.resolved?.detectedVersion} — found on your Mac, '
              'will be reused',
              style: theme.textTheme.muted.copyWith(
                fontSize: 11,
                color: scheme.success,
              ),
            ),
          ),
        const SizedBox(height: 8),
        Divider(color: scheme.border, height: 1),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                'Total download',
                style: theme.textTheme.small
                    .copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              '${formatBytes(inventory.downloadBytes)} · '
              '${formatBytes(inventory.installedBytes)} on disk',
              style: theme.textTheme.small
                  .copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          toolchains.toolchainRootLabel,
          style: theme.textTheme.muted.copyWith(fontSize: 11),
        ),
      ],
    );
  }

  Widget _buildProgress(ShadThemeData theme) {
    final progress = widget.toolchains.progress;
    if (progress == null) return const SizedBox.shrink();
    final active = progress.tools.firstWhere(
      (t) => !t.phase.isTerminal,
      orElse: () => progress.tools.last,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 4),
        Text(
          '${active.phase.label} ${active.id.displayName}…',
          style: theme.textTheme.small.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        DeterminateProgress(
          fraction: progress.fraction,
          caption: formatTransferCaption(
            received: progress.bytesReceived,
            total: progress.bytesTotal,
            eta: progress.eta,
          ),
        ),
        const SizedBox(height: 14),
        for (final tool in progress.tools)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tool.id.displayName,
                    style: theme.textTheme.muted.copyWith(fontSize: 11),
                  ),
                ),
                Text(
                  tool.error ?? tool.phase.label,
                  style: theme.textTheme.muted.copyWith(
                    fontSize: 11,
                    color: tool.phase == ToolPhase.failed
                        ? theme.colorScheme.destructive
                        : null,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
