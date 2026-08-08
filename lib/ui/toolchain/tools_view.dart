import 'package:flutter/foundation.dart';

import '../../toolchain/install_progress.dart';
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
/// Members here are deliberately *narrow*, and shrink as the UI stops asking
/// for things. `toolchainRootLabel`, `requirementLabel`, `upgradeCommand`,
/// `manifestId`, `isRefreshing` and `revealToolchainFolder` all went when the
/// Tools tab became a table: an install path, a version range and a "run this
/// yourself" hint per row were answering questions nobody asked.
abstract interface class ToolsView implements Listenable {
  ToolchainInventory get inventory;

  InstallProgress? get progress;
  String? get installError;

  bool get isBusy;
  bool get isInstalling;

  ShellPathState get shellPathState;

  /// The shell we would edit, e.g. "zsh". Shown when we cannot edit it.
  String get shellName;

  /// The rc file we would edit, already shortened for display.
  String get shellRcLabel;

  /// The exact line the user can copy if they would rather do it themselves.
  String get shellExportLine;

  Future<void> refreshDeep();
  Future<void> refreshShellPathState();

  /// Pulls the newest published manifest and the live size of every artifact it
  /// names — what a download would actually fetch.
  ///
  /// Returns null once that is settled, or a message to put in front of the
  /// user. Awaited rather than watched through a flag, because the setup screen
  /// has nothing to show until it answers. The Tools tab calls it for the
  /// manifest half alone: a managed install can only turn out to be behind if
  /// something newer has been published.
  Future<String?> preflight();

  Future<void> install(List<ToolId> ids);
  Future<void> installMissing();
  Future<void> uninstall(ToolId id);
  void cancelInstall();

  /// Returns an error message, or null on success.
  Future<String?> setShellPathEnabled(bool enabled, {bool force});
}
