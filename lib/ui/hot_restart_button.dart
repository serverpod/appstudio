import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../feature_flags.dart';
import '../mcp/hot_restart_view.dart';
import '../widgets/toolbar_action_button.dart';
import '../widgets/app_dialog.dart';
import '../widgets/dialog_body.dart';

/// Toolbar button that pushes the current code into the running app: it
/// recompiles and reboots the server, then hot-restarts the Flutter app and
/// force-reloads the preview, over `serverpod mcp-server`.
///
/// Named for what it runs — the bridge's `hot_restart`, which unlike
/// `hot_reload` also survives changes to `main()`. It is the fast path; Full
/// Restart bounces the whole `serverpod start` runner.
///
/// Live only while a `serverpod start` is attached to the bridge. Everything
/// else — no project, a server still starting, a bridge that would not run —
/// leaves it disabled and says why in the tooltip, because the alternative is a
/// button that accepts a click and silently does nothing.
///
/// With [kServerpodMcpEnabled] off none of that applies: there is no bridge to
/// be connected to, so the button is always live and always opens
/// [HotRestartComingSoonDialog] instead.
class HotRestartButton extends StatelessWidget {
  const HotRestartButton({super.key, required this.mcp});

  final HotRestartView mcp;

  @override
  Widget build(BuildContext context) {
    // Nothing to listen to: with no bridge the connection never leaves idle,
    // which would otherwise leave a permanently disabled button reading "start
    // the server first" for a server that is already running.
    if (!kServerpodMcpEnabled) {
      return ToolbarActionButton(
        label: 'Hot Restart',
        icon: LucideIcons.zap,
        tooltip: 'Hot restart',
        onPressed: () => unawaited(showHotRestartComingSoonDialog(context)),
      );
    }

    return ListenableBuilder(
      listenable: mcp,
      builder: (context, _) {
        final connection = mcp.mcpConnection;
        final restarting = mcp.isHotRestarting;
        final error = mcp.hotRestartError;
        final enabled = connection == McpConnection.connected && !restarting;

        return ToolbarActionButton(
          label: 'Hot Restart',
          icon: LucideIcons.zap,
          busy: restarting,
          // A failure the user asked for, rather than a connection that never
          // came up: worth colouring, since the button otherwise looks like the
          // click did nothing.
          failed: error != null && connection == McpConnection.connected,
          tooltip: _tooltip(restarting),
          onPressed: enabled ? () => unawaited(mcp.hotRestart()) : null,
        );
      },
    );
  }

  String _tooltip(bool restarting) {
    if (restarting) return 'Hot restarting…';
    return 'Hot restart';
  }
}

/// Raises [HotRestartComingSoonDialog]. Dismissible every way — it reports
/// something rather than asking for a decision, so there is nothing to lose to
/// a stray click on the barrier.
Future<void> showHotRestartComingSoonDialog(BuildContext context) =>
    showAppDialog<void>(
      context: context,
      builder: (context) => const HotRestartComingSoonDialog(),
    );

/// What the Hot Restart button does while [kServerpodMcpEnabled] is off: says
/// App Studio cannot do this yet, and points at the one thing that can do it
/// today — the user's own AI agent, which reaches the same Serverpod MCP tool
/// App Studio will eventually drive itself.
///
/// `ShadDialog.alert` is the variant with no close X, which is right for a
/// notice acknowledged rather than dismissed; the body copy rides in
/// `description` so it lands on `textTheme.muted` rather than the cramped
/// label role.
class HotRestartComingSoonDialog extends StatelessWidget {
  const HotRestartComingSoonDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return ShadDialog.alert(
      title: const Text('Hot restart is coming soon'),
      description: const Text(
        'App Studio cannot hot restart your project yet, but your AI agent '
        'can. Ask it to do a hot restart for you.',
      ),
      actions: [
        ShadButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Got it'),
        ),
      ],
      child: const DialogBody(
        child: ShadAlert(
          icon: Icon(LucideIcons.lightbulb),
          description: Text(
            'Full Restart, next to this button, restarts the server and '
            'reloads the preview from scratch.',
          ),
        ),
      ),
    );
  }
}
