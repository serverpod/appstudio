import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:webview_cef/webview_cef.dart';

import '../agent/agent_controller.dart';
import '../mcp/mcp_controller.dart';
import '../process/serverpod_process.dart';

/// Stops everything a live session owns: the Serverpod server, the CEF
/// preview, the OpenCode agent and the Serverpod MCP bridge.
///
/// Two callers, and they must not drift apart:
///
///  * the window's `dispose()`, on a normal quit;
///  * `UpdateController.prepareForRelaunch()`, before Sparkle swaps the bundle
///    and relaunches.
///
/// The update path is the reason this is time-boxed. A wedged `serverpod` on
/// quit is a nuisance the OS cleans up; during an update it would hold Sparkle
/// open indefinitely, so [timeout] caps the wait and we proceed regardless.
/// Leaving a stray process behind is strictly better than leaving the user on
/// an old build with a half-finished install.
Future<void> teardownSession({
  required ServerpodProcessController process,
  required AgentController agent,
  required McpController mcp,
  Duration timeout = const Duration(seconds: 15),
}) async {
  Future<void> guarded(String what, Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      // Deliberately bare: `WebviewManager.quit()` asserts on an uninitialised
      // manager, and an AssertionError is an Error, not an Exception. Catching
      // only Exception would let it escape asynchronously and abort the
      // teardown halfway — leaving exactly the orphaned processes this exists
      // to prevent.
      debugPrint('teardownSession: $what failed: $e');
    }
  }

  // CEF goes first: its helper processes are children of ours, and quitting the
  // manager after the engine starts tearing down has been a source of hangs.
  // Awaited, because quit() reports failure through its Future.
  await guarded('CEF quit', WebviewManager().quit);

  await Future.wait([
    guarded('server stop', process.stop),
    guarded('agent dispose', () async => agent.dispose()),
    // Awaited rather than left to the controller's own listener: the bridge
    // is a child process, and Sparkle relaunching over one that is still
    // shutting down is exactly the stray process this exists to prevent.
    guarded('mcp stop', mcp.stop),
  ]).timeout(
    timeout,
    onTimeout: () {
      debugPrint('teardownSession: timed out after ${timeout.inSeconds}s');
      return const [];
    },
  );
}
