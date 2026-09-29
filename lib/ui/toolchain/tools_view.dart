import 'package:flutter/foundation.dart';

import '../../toolchain/install_plan.dart';
import '../../toolchain/install_progress.dart';
import '../../toolchain/tool_status.dart';

/// Everything the tools UI needs, and nothing that touches the disk.
///
/// `ToolchainController` implements this directly — no copying, no adapter
/// layer — but the panes import only this file. That is the whole point: the
/// controller spawns processes and reads the filesystem, and a pane that only
/// knows this interface can be driven by a fake — in Widgetbook and in the
/// widget tests — through every state without installing anything.
///
/// It is a [Listenable] so the panes can rebuild on change.
abstract interface class ToolsView implements Listenable {
  ToolchainInventory get inventory;

  /// Whether first-run setup still owns the window: the inventory needs work,
  /// or the one-time Puro/FVM notice has not been answered yet.
  bool get needsSetup;

  /// The one-time notice that App Studio works with a standard Flutter
  /// install only. Due on the first launch, unless one was found.
  bool get needsFlutterNotice;

  /// Records that the notice was answered with Continue.
  Future<void> acknowledgeFlutterNotice();

  /// What an install would fetch — filled in by [preflight].
  InstallPlan get plan;

  InstallProgress? get progress;
  String? get installError;

  bool get isBusy;
  bool get isInstalling;

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
