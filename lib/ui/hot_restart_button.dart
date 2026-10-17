import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../platform/shortcut_hint.dart';
import '../runner/runner_actions_view.dart';
import '../widgets/toolbar_action_button.dart';

/// Toolbar button that recompiles and restarts the server process, then
/// hot-restarts every Flutter app and hard-reloads the preview — the runner's
/// `hotRestart`, also on ⌘R in the Server menu.
///
/// The fast option: it drops in-memory state but picks up anything — `main()`,
/// new dependencies — without the minutes Full Restart of the whole stack
/// takes. There is no Hot Reload beside it: the runner hot-reloads on every
/// save by itself.
///
/// Live only while a runner is attached with its server up and nothing else is
/// in flight. The tooltip says which of those is missing, because the
/// alternative is a button that accepts a click and silently does nothing.
class HotRestartButton extends StatelessWidget {
  const HotRestartButton({super.key, required this.actions});

  final RunnerActionsView actions;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: actions,
      builder: (context, _) {
        final running = actions.runningAction;
        final busy = running == RunnerAction.hotRestart;
        final failed = actions.failedAction == RunnerAction.hotRestart;
        final enabled = actions.canHotRestart && running == null;

        return ToolbarActionButton(
          label: 'Hot Restart',
          icon: LucideIcons.zap,
          busy: busy,
          // A failure the user asked for, rather than an action that was never
          // available: worth colouring, since the button otherwise looks like
          // the click did nothing.
          failed: failed,
          tooltip: _tooltip(busy: busy, failed: failed, running: running),
          onPressed: enabled ? () => unawaited(actions.hotRestart()) : null,
        );
      },
    );
  }

  String _tooltip({
    required bool busy,
    required bool failed,
    required RunnerAction? running,
  }) {
    if (busy) return 'Hot restarting…';
    if (failed) return 'Hot restart failed: ${actions.actionError}';
    if (!actions.canHotRestart) {
      return 'Hot restart — available once the server is running';
    }
    if (running != null) {
      return 'Hot restart — waiting for ${running.label.toLowerCase()} to '
          'finish';
    }
    return 'Hot restart (${shortcutHint('R')})';
  }
}
