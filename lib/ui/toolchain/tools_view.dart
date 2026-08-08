import 'package:flutter/foundation.dart';

import '../../toolchain/install_progress.dart';
import '../../toolchain/toolchain_manifest.dart';
import '../../toolchain/shell_path_state.dart';
import '../../toolchain/tool_status.dart';

/// Everything the tools UI needs, and nothing that touches the disk.
///
/// `ToolchainController` implements this directly — no copying, no adapter
/// layer — but the pane imports only this file. That is the whole point: the
/// controller spawns processes and reads the filesystem, so a pane that
/// imported it could never compile for the widget preview environment, which
/// builds for web.
///
/// It is a [Listenable] so the pane can rebuild on change exactly as before.
///
/// Members here are deliberately *narrow*. The pane used to reach through the
/// controller for `manifest`, `paths` and `requirements` just to build two
/// strings; those are now [upgradeCommand] and [requirementLabel], which keeps
/// command construction and path prettifying out of the widget layer.
abstract interface class ToolsView implements Listenable {
  ToolchainInventory get inventory;

  InstallProgress? get progress;
  String? get installError;

  bool get isBusy;
  bool get isInstalling;
  bool get isRefreshing;

  ShellPathState get shellPathState;

  /// The shell we would edit, e.g. "zsh". Shown when we cannot edit it.
  String get shellName;

  /// The rc file we would edit, already shortened for display.
  String get shellRcLabel;

  /// The exact line the user can copy if they would rather do it themselves.
  String get shellExportLine;

  /// Already shortened for display (`~/Library/...`).
  String get toolchainRootLabel;

  /// Identifies the current set of pinned tool versions. The setup dialog keys
  /// its "Not now" on this, so a new pin re-asks.
  String get manifestId;

  /// The version requirement to show beside a tool, e.g. ">= 4.0.0-beta.1".
  String requirementLabel(ToolSpec spec);

  /// What the user would run to upgrade their *own* copy of a tool, or null
  /// where there is no such command. Never run by us — it mutates an SDK we do
  /// not own.
  String? upgradeCommand(ToolId id);

  Future<void> refreshDeep();
  Future<void> refreshShellPathState();

  Future<void> install(List<ToolId> ids);
  Future<void> installMissing();
  Future<void> uninstall(ToolId id);
  void cancelInstall();

  /// Returns an error message, or null on success.
  Future<String?> setShellPathEnabled(bool enabled, {bool force});

  /// Opens the toolchain folder in Finder.
  Future<void> revealToolchainFolder();
}
