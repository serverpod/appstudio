import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shad/shad.dart';

import '../mcp/hot_restart_view.dart';
import '../widgets/toolbar_action_button.dart';

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
class HotRestartButton extends StatelessWidget {
  const HotRestartButton({super.key, required this.mcp});

  final HotRestartView mcp;

  @override
  Widget build(BuildContext context) {
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
          tooltip: _tooltip(connection, restarting, error),
          onPressed: enabled ? () => unawaited(mcp.hotRestart()) : null,
        );
      },
    );
  }

  String _tooltip(McpConnection connection, bool restarting, String? error) {
    if (restarting) return 'Hot restarting…';
    return switch (connection) {
      McpConnection.connected when error != null => 'Hot restart failed: $error',
      McpConnection.connected => 'Hot Restart — recompile the server and app',
      McpConnection.idle => 'Hot Restart — start the server first',
      McpConnection.connecting => 'Hot Restart — connecting to the server',
      McpConnection.unavailable =>
        'Hot Restart unavailable${error == null ? '' : ': $error'}',
    };
  }
}
