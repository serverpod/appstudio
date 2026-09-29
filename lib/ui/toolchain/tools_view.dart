import 'package:flutter/foundation.dart';

import '../../toolchain/install_plan.dart';
import '../../toolchain/install_progress.dart';
import '../../toolchain/tool_status.dart';

/// Everything the tools UI needs, and nothing that touches the disk.
///
/// `ToolchainController` implements this directly — no copying, no adapter
/// layer — but the panes import only this file. That is the whole point: the
/// controller spawns processes and reads the filesystem, so a pane that
/// imported it could never compile for the widget preview environment, which
/// builds for web.
///
/// It is a [Listenable] so the panes can rebuild on change.
abstract interface class ToolsView implements Listenable {
  ToolchainInventory get inventory;

  /// What an install would fetch — filled in by [preflight].
  InstallPlan get plan;

  InstallProgress? get progress;
  String? get installError;

  bool get isBusy;
  bool get isInstalling;

  /// Where a Flutter SDK App Studio installs goes, shortened for display.
  String get flutterInstallLabel;

  /// The shell config `PATH` lines go into, shortened for display. Null for a
  /// shell App Studio cannot edit.
  String? get shellProfileLabel;

  /// `PATH` lines the user has to add by hand, because App Studio cannot edit
  /// their shell's config. Empty in the ordinary case.
  List<String> get manualPathLines;

  Future<void> refreshDeep();

  /// Looks up what an install would fetch — the newest Flutter release and
  /// Serverpod CLI version inside the manifest's ranges — into [plan].
  ///
  /// Returns null once that is settled, or a message to put in front of the
  /// user. Awaited rather than watched through a flag, because the setup
  /// screen has nothing to show until it answers.
  Future<String?> preflight();

  /// Installs or updates everything App Studio can on its own, in order.
  Future<void> installMissing();
  void cancelInstall();

  /// Removes what an earlier build installed into Application Support, and
  /// its shell `PATH` block. Returns an error message, or null on success.
  Future<String?> removeLegacyInstall();
}
