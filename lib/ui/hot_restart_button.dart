import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shad/shad.dart';

import '../mcp/hot_restart_view.dart';
import '../theme/app_theme.dart';

/// Toolbar button that recompiles and reboots the running server, then
/// hot-restarts the Flutter app, over `serverpod mcp-server`.
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
        final theme = ShadTheme.of(context);
        final scheme = theme.colorScheme;
        final connection = mcp.mcpConnection;
        final restarting = mcp.isHotRestarting;
        final error = mcp.hotRestartError;
        final enabled = connection == McpConnection.connected && !restarting;
        // A failure the user asked for, rather than a connection that never
        // came up: worth colouring, since the button otherwise looks like the
        // click did nothing.
        final failed = error != null && connection == McpConnection.connected;

        return ShadTooltip(
          builder: (context) => Text(_tooltip(connection, restarting, error)),
          // Wrapping the button rather than being wrapped *by* it. A disabled
          // `ShadButton` puts its content behind an `AbsorbPointer`, which eats
          // the hover `ShadTooltip` listens for — so the tooltip explaining why
          // the button is disabled would never appear, which is precisely when
          // it is worth reading. This detector sits outside that.
          child: ShadGestureDetector(
            child: ShadIconButton.ghost(
              // `enabled` is what drives the disabled styling — a null handler
              // on its own leaves the button inert but looking live.
              enabled: enabled,
              onPressed: enabled ? () => unawaited(mcp.hotRestart()) : null,
              width: kToolbarIconButtonSize,
              height: kToolbarIconButtonSize,
              icon: restarting
                  ? const ShadSpinner(size: 14)
                  : Icon(
                      LucideIcons.zap,
                      size: 16,
                      color: failed ? scheme.destructive : null,
                    ),
            ),
          ),
        );
      },
    );
  }

  String _tooltip(McpConnection connection, bool restarting, String? error) {
    if (restarting) return 'Hot restarting…';
    return switch (connection) {
      McpConnection.connected when error != null => 'Hot restart failed: $error',
      McpConnection.connected => 'Hot restart the server and app',
      McpConnection.idle => 'Hot restart — start the server first',
      McpConnection.connecting => 'Hot restart — connecting to the server',
      McpConnection.unavailable =>
        'Hot restart unavailable${error == null ? '' : ': $error'}',
    };
  }
}
