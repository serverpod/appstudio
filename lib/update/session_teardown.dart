import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:webview_cef/webview_cef.dart';

import '../agent/agent_controller.dart';
import '../process/serverpod_process.dart';

/// Stops everything a live session owns: the Serverpod runner App Studio
/// started (one it only attached to is detached from), the CEF preview and the
/// OpenCode agent.
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
  //
  // Only when it is actually up. `WebviewManager` is a singleton that only
  // initializes CEF once a preview pane mounts, so quitting with no project
  // open used to log a failed teardown for something that was never started —
  // and in a release build, where `quit()`'s own assert is compiled out, it
  // would reach `CefShutdown()` on a CEF that was never initialized.
  if (WebviewManager().value) {
    await guarded('CEF quit', WebviewManager().quit);
  }

  await Future.wait([
    // Awaited, and it matters more than it used to: the runner is detached, so
    // nothing takes it down with us. One left running would hold the project
    // until the user found it with `serverpod runner stop`.
    guarded('server stop', process.stop),
    // `stop`, not `dispose`. `dispose()` is synchronous and could only fire the
    // teardown and return, so every quit left an orphaned `opencode serve`
    // reparented to launchd — 17 of them on the machine where this was found.
    guarded('agent stop', agent.stop),
  ]).timeout(
    timeout,
    onTimeout: () {
      debugPrint('teardownSession: timed out after ${timeout.inSeconds}s');
      return const [];
    },
  );
}
