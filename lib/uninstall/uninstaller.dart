import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../agent/agent_controller.dart';
import '../process/serverpod_process.dart';
import '../toolchain/tool_status.dart';
import '../toolchain/toolchain_controller.dart';
import '../update/session_teardown.dart';
import 'uninstall_result.dart';

export 'uninstall_result.dart';

/// Removes what App Studio put on this Mac, apart from the app bundle.
///
/// Always:
///
///  * `~/Library/Application Support/App Studio` — App Studio's own data.
///  * Whatever an earlier build left for tools: its private toolchain and the
///    fenced `PATH` block in the user's shell config.
///  * Preferences (NSUserDefaults) — recents, theme, notice dismissals.
///    Without clearing these a reinstall would not behave like a fresh one.
///
/// And each tool App Studio installed that the user ticked. Those are real
/// installs now, in the places their own instructions put them, so other
/// things may use them — which is why they are a choice and not implied:
///
///  * the Serverpod CLI (`dart uninstall`), and with it `~/.serverpod` — the
///    CLI's own state, including the Serverpod Cloud login;
///  * the Flutter SDK, and the `PATH` line App Studio added for it;
///  * the Command Line Tools, behind an administrator prompt.
///
/// `~/.pub-cache` goes with Flutter — it is Flutter's Dart's package cache —
/// and stays when Flutter does.
///
/// Deliberately never removed: anything App Studio did not install, and
/// `~/.local/share/opencode/auth.json` (keys the OpenCode CLI uses on its own).
class Uninstaller {
  const Uninstaller({
    required this.toolchains,
    required this.process,
    required this.agent,
  });

  final ToolchainController toolchains;
  final ServerpodProcessController process;
  final AgentController agent;

  Future<UninstallResult> run(UninstallChoice choice) async {
    final failures = <String>[];

    Future<void> step(String what, Future<void> Function() action) async {
      try {
        await action();
      } catch (e) {
        debugPrint('Uninstaller: $what failed: $e');
        failures.add(what);
      }
    }

    // Stop the world first. Deleting a tool out from under a running server
    // would leave processes pointing at missing binaries.
    await step('shutting down the session', () async {
      await teardownSession(process: process, agent: agent);
    });

    // Both need Dart, so both run before Flutter can go.
    if (choice.tools.contains(ToolId.serverpodCli)) {
      await step('uninstalling Serverpod', () async {
        await toolchains.uninstallTool(ToolId.serverpodCli);
      });
    }
    if (choice.clearPubCache) {
      await step('clearing the Dart package cache', () async {
        final error = await toolchains.clearPubCache();
        if (error != null) throw StateError(error);
      });
    }
    if (choice.tools.contains(ToolId.flutter)) {
      await step('uninstalling Flutter', () async {
        await toolchains.uninstallTool(ToolId.flutter);
      });
    }
    if (choice.tools.contains(ToolId.commandLineTools)) {
      await step('uninstalling Apple\'s command line tools', () async {
        await toolchains.uninstallTool(ToolId.commandLineTools);
      });
    }

    await step('removing tools from earlier versions', () async {
      final error = await toolchains.removeLegacyInstall();
      if (error != null) throw StateError(error);
    });

    await step('deleting the App Studio support folder', () async {
      final dir = Directory(toolchains.paths.appSupportRoot);
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    // The CLI's own state goes with the CLI. After the session is down: the
    // CLI writes here on every run, and the cloud CLI holds its login here.
    if (choice.tools.contains(ToolId.serverpodCli)) {
      await step('deleting Serverpod\'s settings', () async {
        final dir = Directory(toolchains.paths.serverpodStateDir);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
        // The install record lived in there. Whatever App Studio installed and
        // the user chose to keep is still its to offer next time.
        await toolchains.persistRecord();
      });
    }

    // Last, so a crash earlier still leaves the app able to explain itself.
    await step('clearing preferences', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    });

    return UninstallResult(failures: failures);
  }
}
