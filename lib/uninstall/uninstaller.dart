import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../agent/agent_controller.dart';
import '../mcp/mcp_controller.dart';
import '../process/serverpod_process.dart';
import '../toolchain/shim_writer.dart';
import '../toolchain/toolchain_controller.dart';
import '../update/session_teardown.dart';
import '../util/home_dir.dart';
import 'uninstall_result.dart';

export 'uninstall_result.dart';

/// Removes everything App Studio put on this Mac, apart from the app bundle.
///
/// Four stores, only one of which is the Application Support directory:
///
///  * `~/Library/Application Support/App Studio` — the toolchain, shims,
///    manifests and install state.
///  * The `PATH` block in the user's shell rc file, which lives in the home
///    directory. Leaving it behind would point their shell at a directory that
///    no longer exists, in every new terminal, forever.
///  * `~/.serverpod` — the Serverpod CLI's own state: per-version template
///    caches, the analytics id and run counter, the latest-version check and
///    the cloud CLI's login. The CLI we ran wrote it, and a fresh install
///    would otherwise inherit it.
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
    required this.mcp,
    this.homeOverride,
  });

  final ToolchainController toolchains;
  final ServerpodProcessController process;
  final AgentController agent;
  final McpController mcp;

  /// Where `~/.serverpod` is looked for; `$HOME` when null. Tests point it at
  /// a scratch directory so they never touch the real one.
  final String? homeOverride;

  /// The Serverpod CLI's state directory, or null when there is no home.
  String? get serverpodStateDir {
    final home = homeOverride ?? homeDirectory();
    if (home == null || home.isEmpty) return null;
    return '$home/.serverpod';
  }

  /// Total size of the Application Support directory, or null if it cannot be
  /// measured. Used by the confirmation dialog, which takes it as a callback so
  /// it stays free of `dart:io`.
  Future<int?> measureSupportBytes() async {
    try {
      final result = await Process.run(
        '/usr/bin/du',
        ['-sk', toolchains.paths.appSupportRoot],
      );
      if (result.exitCode != 0) return null;
      final kb = int.tryParse(
        (result.stdout as String).trim().split(RegExp(r'\s+')).first,
      );
      return kb == null ? null : kb * 1024;
    } catch (_) {
      return null;
    }
  }

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
      await teardownSession(process: process, agent: agent, mcp: mcp);
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

    // After the session is down: the CLI writes here on every run, and the
    // cloud CLI holds its login here, so this is only safe once nothing of
    // ours can start either.
    await step('deleting the Serverpod CLI settings folder', () async {
      final path = serverpodStateDir;
      if (path == null) return;
      final dir = Directory(path);
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
