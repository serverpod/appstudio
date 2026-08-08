import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../theme/app_theme.dart';
import '../../toolchain/install_progress.dart';
import '../../toolchain/tool_status.dart';
import '../../util/byte_format.dart';
import '../../util/quit_app.dart';
import '../../widgets/determinate_progress.dart';
import '../../widgets/error_banner.dart';
import '../../widgets/settings_table.dart';
import 'install_globally_checkbox.dart';
import 'tools_view.dart';

/// Raises the download plan. Completes when the toolchain is in place — the
/// dialog closes itself — or never, if the user quits from it.
///
/// The caller is expected to have run [ToolsView.preflight] first: the plan is
/// the *whole* content of this dialog, so opening it before the sizes and
/// versions have arrived leaves an empty box on screen.
Future<void> showToolchainSetupDialog(
  BuildContext context, {
  required ToolsView toolchains,
}) async {
  await showShadDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierBlurSigma: 0,
    builder: (context) => ToolchainSetupDialog(toolchains: toolchains),
  );
}

/// Reports a preflight that could not produce a plan, and offers to retry.
///
/// Completes when the user asks to try again; quitting exits the process, so
/// there is no second return path to handle.
Future<void> showToolchainSetupErrorDialog(
  BuildContext context, {
  required String message,
}) async {
  await showShadDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierBlurSigma: 0,
    builder: (context) => ToolchainSetupErrorDialog(message: message),
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
  bool _installGlobally = true;

  /// Guards the self-close: the controller notifies several times as the last
  /// install settles, and popping a route twice throws.
  bool _closing = false;

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
    if (!_closing &&
        !toolchains.isInstalling &&
        toolchains.progress != null &&
        toolchains.inventory.installable.isEmpty &&
        toolchains.installError == null) {
      _closing = true;
      // `pop`, not `maybePop`: the PopScope below refuses the user's own
      // dismissal, and maybePop honours it, so it would refuse this too.
      Navigator.of(context).pop();
    }
  }

  Future<void> _download() async {
    await widget.toolchains.installMissing();
    if (!mounted || !_installGlobally) return;
    await widget.toolchains.setShellPathEnabled(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final toolchains = widget.toolchains;
    final installing = toolchains.isInstalling;

    return PopScope(
      // Nothing downstream works without these tools, and this is the only
      // thing on screen, so a dismissal would strand the user on an empty
      // window. Quit is the way out; the dialog closes itself when done.
      canPop: false,
      child: ShadDialog.alert(
        title: const Text('Set up toolchain'),
        description: const Text(
          'App Studio will download these tools to Application Support. '
          'Use the Uninstall command to remove them from your computer.',
        ),
        actions: installing
            ? [
                ShadButton.outline(
                  onPressed: toolchains.cancelInstall,
                  child: const Text('Cancel'),
                ),
              ]
            : [
                ShadButton.outline(
                  onPressed: quitApp,
                  child: const Text('Quit'),
                ),
                ShadButton(
                  onPressed: _download,
                  child: const Text('Download'),
                ),
              ],
        child: SizedBox(
          width: double.infinity,
          child: installing ? _buildProgress(theme) : _buildPlan(theme),
        ),
      ),
    );
  }

  Widget _buildPlan(ShadThemeData theme) {
    final toolchains = widget.toolchains;
    final inventory = toolchains.inventory;

    final reused = [
      for (final status in inventory.tools.values)
        if (status.resolved case final r? when r.source == ToolSource.host)
          status,
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (toolchains.installError case final error?) ...[
          ErrorBanner(message: error),
          const SizedBox(height: 12),
        ],
        SettingsTable(
          rows: [
            for (final status in inventory.installable)
              SettingsTableRow(
                name: status.spec.displayName,
                badge: versionBadge(
                  status.spec.version,
                  replacing: status.bestRejected?.detectedVersion,
                ),
                trailing: Text(
                  formatBytes(
                    status.spec.artifactForCurrentPlatform!.downloadBytes,
                  ),
                  style: theme.textTheme.muted,
                ),
              ),
            for (final status in reused)
              SettingsTableRow(
                name: status.spec.displayName,
                badge: versionBadge(status.resolved!.detectedVersion!),
                trailing: appSuccessBadge(
                  theme,
                  child: const Text('Installed'),
                ),
              ),
          ],
        ),
        const ShadGap(3),
        InstallGloballyCheckbox(
          value: _installGlobally,
          onChanged: (v) => setState(() => _installGlobally = v),
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
          style: theme.textTheme.small.semibold,
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

/// Shown when the preflight could not work out what to download — in practice,
/// no route to the bucket.
///
/// There is no degraded mode to offer: the app cannot build a Serverpod project
/// without these tools, and it cannot fetch them without a network. So the two
/// honest choices are to retry and to quit.
class ToolchainSetupErrorDialog extends StatelessWidget {
  const ToolchainSetupErrorDialog({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: ShadDialog.alert(
        title: const Text('Could not prepare the download'),
        description: const Text(
          'App Studio needs to download the tools it builds and runs Serverpod '
          'projects with before it can open a project.',
        ),
        actions: [
          ShadButton.outline(
            onPressed: quitApp,
            child: const Text('Quit'),
          ),
          ShadButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Try again'),
          ),
        ],
        child: SizedBox(
          width: double.infinity,
          child: ErrorBanner(message: message),
        ),
      ),
    );
  }
}
