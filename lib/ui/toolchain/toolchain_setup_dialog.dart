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
import 'tools_view.dart';
import '../../widgets/app_dialog.dart';

/// Raises the install plan. Completes when the toolchain is in place — the
/// dialog closes itself — or never, if the user quits from it.
///
/// The caller is expected to have run [ToolsView.preflight] first: the plan is
/// the *whole* content of this dialog, so opening it before the versions have
/// arrived leaves an empty box on screen.
Future<void> showToolchainSetupDialog(
  BuildContext context, {
  required ToolsView toolchains,
}) async {
  await showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierBlurSigma: 0,
    builder: (context) => ToolchainSetupDialog(toolchains: toolchains),
  );
}

/// Reports a step of setup that could not go ahead, and offers to retry.
///
/// Completes when the user asks to try again; quitting exits the process, so
/// there is no second return path to handle.
Future<void> showToolchainSetupErrorDialog(
  BuildContext context, {
  required String message,
  String title = 'Could not prepare the install',
}) async {
  await showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierBlurSigma: 0,
    builder: (context) =>
        ToolchainSetupErrorDialog(title: title, message: message),
  );
}

/// First-run plan: which tools will be installed, where, and how.
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

  /// True from the moment Install is pressed until the install has returned.
  /// `toolchains.isInstalling` covers the same span today; this keeps the
  /// progress view up if the two ever come apart.
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

  /// Closes once everything is in place — but never while this dialog still
  /// has work of its own outstanding.
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

  Future<void> _install() async {
    setState(() => _running = true);
    try {
      await widget.toolchains.installMissing();
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
        title: const Text('Set up your tools'),
        description: installing ? null : Text(_planDescription()),
        actions: installing
            ? [
                // Stops after the step in progress. Apple's installer is its
                // own app and carries on regardless.
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
                  onPressed: () => unawaited(_install()),
                  child: const Text('Install'),
                ),
              ],
        child: SizedBox(
          width: double.infinity,
          child: installing ? _buildProgress(theme) : _buildPlan(theme),
        ),
      ),
    );
  }

  /// Says where each tool is about to go — this edits the user's machine
  /// outside the app, so it names every place it touches.
  String _planDescription() {
    final toolchains = widget.toolchains;
    final ids = {for (final t in toolchains.inventory.installable) t.id};
    final parts = [
      if (ids.contains(ToolId.commandLineTools))
        'Apple\'s Command Line Tools, through Apple\'s own installer',
      if (toolchains.inventory[ToolId.flutter]?.action == ToolAction.install)
        'Flutter in ${toolchains.flutterInstallLabel}',
      if (ids.contains(ToolId.serverpodCli))
        'the Serverpod CLI with dart install',
    ];
    final buffer = StringBuffer('App Studio installs these the standard way');
    if (parts.isNotEmpty) buffer.write(': ${_sentenceList(parts)}');
    buffer.write('.');
    if (toolchains.shellProfileLabel case final profile?) {
      buffer.write(
        ' It adds them to your PATH in $profile, so your terminal and '
        'editors use the same tools.',
      );
    }
    return buffer.toString();
  }

  Widget _buildPlan(ShadThemeData theme) {
    final toolchains = widget.toolchains;
    final inventory = toolchains.inventory;

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
            for (final id in ToolId.values)
              if (inventory[id] case final status?) _row(theme, status),
          ],
        ),
      ],
    );
  }

  SettingsTableRow _row(ShadThemeData theme, ToolStatus status) {
    final planned = widget.toolchains.plan[status.id];
    if (status.resolved case final resolved?) {
      return SettingsTableRow(
        name: status.spec.displayName,
        badge: switch (resolved.detectedVersion) {
          final version? => versionBadge(version),
          null => null,
        },
        trailing: appSuccessBadge(theme, child: const Text('Installed')),
      );
    }
    final replacing = status.bestRejected?.detectedVersion;
    return SettingsTableRow(
      name: status.spec.displayName,
      badge: switch (planned?.version) {
        final version? => versionBadge(version, replacing: replacing),
        null => null,
      },
      // How it arrives: the size where there is one to quote, otherwise the
      // route — neither Apple's installer nor the two commands say up front.
      trailing: Text(
        switch ((status.id, planned?.downloadBytes)) {
          (_, final bytes?) => formatBytes(bytes),
          (ToolId.commandLineTools, _) => 'From Apple',
          (ToolId.flutter, _) => 'flutter upgrade',
          (ToolId.serverpodCli, _) => 'dart install',
        },
        style: theme.textTheme.muted,
      ),
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
          caption: progress == null ? null : installCaption(progress),
        ),
        const ShadGap(4),
      ],
    );
  }
}

/// The line under the bar: bytes while downloading, otherwise what the step
/// is doing. Shared with the Tools tab's banner.
String? installCaption(InstallProgress progress) {
  final detail = progress.isDownloading
      ? formatTransferCaption(
          received: progress.bytesReceived,
          total: progress.bytesTotal,
          eta: progress.eta,
        )
      : progress.hint;
  final parts = [?progress.stepLabel, ?detail];
  return parts.isEmpty ? null : parts.join(' · ');
}

String _sentenceList(List<String> parts) => switch (parts.length) {
      1 => parts.single,
      2 => '${parts.first} and ${parts.last}',
      _ => '${parts.take(parts.length - 1).join(', ')} and ${parts.last}',
    };

/// Shown when a setup step could not go ahead — in practice, no network, or
/// old files that could not be removed.
///
/// There is no degraded mode to offer: the app cannot build a Serverpod
/// project without these tools. So the two honest choices are to retry and to
/// quit.
class ToolchainSetupErrorDialog extends StatelessWidget {
  const ToolchainSetupErrorDialog({
    super.key,
    required this.message,
    this.title = 'Could not prepare the install',
  });

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: ShadDialog.alert(
        title: Text(title),
        description: const Text(
          'App Studio needs Flutter and the Serverpod CLI before it can '
          'create or open a project.',
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
