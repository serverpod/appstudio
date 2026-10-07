import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../runner/runner_actions_view.dart';
import '../widgets/toolbar_action_button.dart';

/// Toolbar button that hot-reloads the running project: the server isolate,
/// then every running Flutter app. Fast, and keeps in-memory state — which is
/// also why it does not pick up a change to `main()`.
class HotReloadButton extends StatelessWidget {
  const HotReloadButton({super.key, required this.actions});

  final RunnerActionsView actions;

  @override
  Widget build(BuildContext context) => _RunnerActionButton(
        actions: actions,
        action: RunnerAction.hotReload,
        icon: LucideIcons.zap,
        idleTooltip: 'Hot reload — apply code changes, keeping app state',
        busyTooltip: 'Hot reloading…',
        onPressed: actions.hotReload,
      );
}

/// Toolbar button that recompiles and restarts the server process, then
/// hot-restarts every Flutter app and hard-reloads the preview.
///
/// The middle option: slower than [HotReloadButton] and drops state, but picks
/// up anything — `main()`, new dependencies — without the minutes a Full
/// Restart of the whole stack takes.
class HotRestartButton extends StatelessWidget {
  const HotRestartButton({super.key, required this.actions});

  final RunnerActionsView actions;

  @override
  Widget build(BuildContext context) => _RunnerActionButton(
        actions: actions,
        action: RunnerAction.hotRestart,
        icon: LucideIcons.refreshCcwDot,
        idleTooltip: 'Hot restart — restart the server and the app',
        busyTooltip: 'Hot restarting…',
        onPressed: actions.hotRestart,
      );
}

/// Both buttons go through the runner's socket, so they share one rule set:
/// live only while a runner is attached with its server up and nothing else
/// is in flight. The tooltip says which of those is missing, because the
/// alternative is a button that accepts a click and silently does nothing.
class _RunnerActionButton extends StatelessWidget {
  const _RunnerActionButton({
    required this.actions,
    required this.action,
    required this.icon,
    required this.idleTooltip,
    required this.busyTooltip,
    required this.onPressed,
  });

  final RunnerActionsView actions;
  final RunnerAction action;
  final IconData icon;
  final String idleTooltip;
  final String busyTooltip;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: actions,
      builder: (context, _) {
        final running = actions.runningAction;
        final busy = running == action;
        final failed = actions.failedAction == action;
        final enabled = actions.canHotReload && running == null;

        return ToolbarActionButton(
          label: action.label,
          icon: icon,
          busy: busy,
          // A failure the user asked for, rather than an action that was never
          // available: worth colouring, since the button otherwise looks like
          // the click did nothing.
          failed: failed,
          tooltip: _tooltip(busy: busy, failed: failed, running: running),
          onPressed: enabled ? () => unawaited(onPressed()) : null,
        );
      },
    );
  }

  String _tooltip({
    required bool busy,
    required bool failed,
    required RunnerAction? running,
  }) {
    if (busy) return busyTooltip;
    if (failed) return '${action.label} failed: ${actions.actionError}';
    if (!actions.canHotReload) {
      return '${action.label} — available once the server is running';
    }
    if (running != null) {
      return '${action.label} — waiting for ${running.label.toLowerCase()} '
          'to finish';
    }
    return idleTooltip;
  }
}
