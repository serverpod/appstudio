import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../theme/app_theme.dart';
import '../../toolchain/tool_status.dart';
import '../../util/byte_format.dart';
import '../../util/quit_app.dart';
import '../../widgets/determinate_progress.dart';
import '../../widgets/error_banner.dart';
import '../../widgets/settings_table.dart';
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
  /// Guards the self-close: the controller notifies several times as the last
  /// install settles, and popping a route twice throws.
  bool _closing = false;

  /// True from the moment Download is pressed until every step this dialog owns
  /// has finished. `toolchains.isInstalling` covers the downloads and the
  /// re-probe; the global PATH write happens after that returns and is ours
  /// alone to wait for. Without it the dialog dropped back to its download plan
  /// for the tail of the run, so the last thing the user saw before it closed
  /// was the screen they started on.
  bool _running = false;

  /// The route this dialog sits on, so the self-close can tell "still mine to
  /// close" from "already taken off by someone else". Captured here rather than
  /// read at close time: by then the element may no longer find it.
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    widget.toolchains.addListener(_onToolchains);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void dispose() {
    widget.toolchains.removeListener(_onToolchains);
    super.dispose();
  }

  void _onToolchains() {
    if (!mounted) return;
    setState(() {});
    _closeIfComplete();
  }

  /// Closes once everything required is in place — but never while this dialog
  /// still has work of its own outstanding.
  void _closeIfComplete() {
    if (_closing || _running) return;
    final toolchains = widget.toolchains;
    if (toolchains.isInstalling ||
        toolchains.progress == null ||
        toolchains.inventory.installable.isNotEmpty ||
        toolchains.installError != null) {
      return;
    }
    // `main.dart` drops everything pushed over `home` the moment the toolchain
    // gate flips, and that flip arrives while this dialog is still finishing
    // up — so it is routinely closed from outside. Popping anyway would pop
    // `home` instead and leave an empty navigator: a white window, with the
    // start page it should have revealed animating away.
    if (_route?.isCurrent != true) return;
    _closing = true;
    // `pop`, not `maybePop`: the PopScope below refuses the user's own
    // dismissal, and maybePop honours it, so it would refuse this too.
    Navigator.of(context).pop();
  }

  Future<void> _download() async {
    setState(() => _running = true);
    try {
      await widget.toolchains.installMissing();
      // Unconditional: putting the tools on the user's own `PATH` is what lets
      // an external editor or AI agent find them, and with App Studio's own
      // agent gone that is the only way they are reached from outside. It was
      // an opt-in checkbox here, which is a question with one useful answer.
      if (mounted) {
        await widget.toolchains.setShellPathEnabled(true);
      }
    } finally {
      if (mounted) {
        setState(() => _running = false);
        // The listener that would normally close us fired while `_running` held
        // it off, so the last word is this one.
        _closeIfComplete();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final toolchains = widget.toolchains;
    final installing = _running || toolchains.isInstalling;
    final canCancel = toolchains.progress?.isDone == false;

    return PopScope(
      // Nothing downstream works without these tools, and this is the only
      // thing on screen, so a dismissal would strand the user on an empty
      // window. Quit is the way out; the dialog closes itself when done.
      canPop: false,
      child: ShadDialog.alert(
        title: const Text('Set up toolchain'),
        description: installing
            ? null
            : const Text(
                'App Studio will download these tools to Application Support. '
                'Use the Uninstall command to remove them from your computer.',
              ),
        actions: installing
            ? [
                // Only a download can be called off. Past that the tools are on
                // disk and the rest is bookkeeping, so the button stays in
                // place and dims rather than disappearing under the pointer.
                ShadButton.outline(
                  enabled: canCancel,
                  onPressed: canCancel ? toolchains.cancelInstall : null,
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
      ],
    );
  }

  Widget _buildProgress(ShadThemeData theme) {
    final progress = widget.toolchains.progress;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 4),
        Text(
          // No progress yet means a run that has not published its first update
          // — the tail state, and the only honest thing to call it.
          progress?.statusLabel ?? 'Finishing up…',
          style: theme.textTheme.small.semibold,
        ),
        const SizedBox(height: 12),
        DeterminateProgress(
          fraction: progress?.fraction,
          caption: progress == null
              ? null
              : formatTransferCaption(
                  received: progress.bytesReceived,
                  total: progress.bytesTotal,
                  eta: progress.eta,
                ),
        ),
        const ShadGap(4),
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
