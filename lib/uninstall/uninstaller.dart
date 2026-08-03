import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../agent/agent_controller.dart';
import '../process/serverpod_process.dart';
import '../toolchain/shim_writer.dart';
import '../toolchain/toolchain_controller.dart';
import '../update/session_teardown.dart';

/// What a full uninstall removed, for the confirmation screen.
@immutable
class UninstallResult {
  const UninstallResult({required this.failures});

  /// Steps that did not complete. The uninstall never aborts on one of these:
  /// stopping halfway would leave the user with neither a working install nor
  /// a clean machine, and no way to tell which.
  final List<String> failures;

  bool get isClean => failures.isEmpty;
}

/// Removes everything App Studio put on this Mac, apart from the app bundle.
///
/// Three stores, only one of which is the Application Support directory:
///
///  * `~/Library/Application Support/App Studio` — the toolchain, shims,
///    manifests and install state.
///  * The `PATH` block in the user's shell rc file, which lives in the home
///    directory. Leaving it behind would point their shell at a directory that
///    no longer exists, in every new terminal, forever.
///  * Preferences (NSUserDefaults) — recents, theme, the toolchain-setup
///    dismissal. Without clearing these a reinstall would not behave like a
///    fresh one, which is the whole point.
///
/// Deliberately NOT removed, because they are shared with things that are not
/// App Studio: `~/.pub-cache` (offered separately, off by default) and
/// `~/.local/share/opencode/auth.json`, which holds API keys the OpenCode CLI
/// uses independently.
class Uninstaller {
  const Uninstaller({
    required this.toolchains,
    required this.process,
    required this.agent,
  });

  final ToolchainController toolchains;
  final ServerpodProcessController process;
  final AgentController agent;

  Future<UninstallResult> run({bool clearPubCache = false}) async {
    final failures = <String>[];

    Future<void> step(String what, Future<void> Function() action) async {
      try {
        await action();
      } catch (e) {
        debugPrint('Uninstaller: $what failed: $e');
        failures.add(what);
      }
    }

    // Stop the world first. Deleting the toolchain out from under a running
    // serverpod or opencode would leave processes pointing at missing binaries.
    await step('shutting down the session', () async {
      await teardownSession(process: process, agent: agent);
    });

    // Before deleting the directory: this edits the shell rc file, and the
    // removal path reads the shim directory to know what it wrote.
    await step('removing the shell PATH entry', () async {
      // Returns its error rather than throwing, so it has to be checked — an
      // unchecked call here would report a clean uninstall while leaving a
      // dead PATH entry in the user's shell.
      final error = await toolchains.setShellPathEnabled(false, force: true);
      // Shims are removed by the call above, but only if it got that far.
      await ShimWriter(binDir: toolchains.paths.shimBinDir).removeAll();
      if (error != null) throw StateError(error);
    });

    if (clearPubCache) {
      await step('clearing the Dart package cache', () async {
        final error = await toolchains.clearPubCache();
        if (error != null) throw StateError(error);
      });
    }

    await step('deleting the App Studio support folder', () async {
      final dir = Directory(toolchains.paths.appSupportRoot);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    // Last, so a crash earlier still leaves the app able to explain itself.
    await step('clearing preferences', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    });

    return UninstallResult(failures: failures);
  }
}
