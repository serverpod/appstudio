import 'dart:async';
import 'dart:ui' show AppExitType;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../widgets/app_dialog.dart';
import 'appcast.dart';
import 'linux_update_dialog.dart';
import 'linux_updater.dart';

/// Help → Check for Updates on Linux. [onChecked] runs after every check,
/// so the menu can refresh what it shows. [quit] is File → Quit's teardown
/// and exit, replaceable in tests.
Future<void> checkForUpdatesOnLinux(
  BuildContext context,
  LinuxUpdater updater, {
  VoidCallback? onChecked,
  @visibleForTesting Future<void> Function()? quit,
}) async {
  final current = await updater.runningVersion();
  if (current == null || !context.mounted) return;
  await showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => LinuxUpdateDialog.check(
      current: current,
      check: () async {
        try {
          return await updater.check();
        } finally {
          onChecked?.call();
        }
      },
      install: _installer(updater, quit ?? _quitApp, ModalRoute.of(context)),
      onSkip: updater.skip,
    ),
  );
}

/// The automatic check: at most once a day, and only over the start page,
/// where no server is running. An update the user skipped is not offered
/// again; a newer one is. Says nothing when there is no update, or when
/// the check fails.
class LinuxUpdateSchedule {
  LinuxUpdateSchedule(
    this.updater, {
    DateTime Function()? now,
    @visibleForTesting Future<void> Function()? quit,
  }) : _now = now ?? DateTime.now,
       _quit = quit ?? _quitApp;

  final LinuxUpdater updater;
  final DateTime Function() _now;
  final Future<void> Function() _quit;
  bool _running = false;

  Future<void> checkIfDue(
    BuildContext context, {
    required bool Function() onStartPage,
    VoidCallback? onChecked,
  }) async {
    if (_running) return;
    _running = true;
    try {
      if (!onStartPage() || !await updater.isCheckDue(_now())) return;
      final AppcastItem? update;
      try {
        update = await updater.check();
      } on LinuxUpdateException catch (e) {
        debugPrint('Automatic update check failed: $e');
        return;
      } finally {
        onChecked?.call();
      }
      if (update == null) return;
      final skipped = await updater.skippedBuild();
      if (skipped != null && update.version.build <= skipped) return;
      final current = await updater.runningVersion();
      // Checked again: the check took time, and a project may be open now.
      if (current == null || !context.mounted || !onStartPage()) return;
      await showAppDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => LinuxUpdateDialog.offer(
          current: current,
          update: update!,
          install: _installer(updater, _quit, ModalRoute.of(context)),
          onSkip: updater.skip,
        ),
      );
    } finally {
      _running = false;
    }
  }
}

/// Installs only while [dialog] is the route on top. The menu strip's
/// shortcuts still work under the dialog, so New Project (Ctrl+N) or
/// Settings (Ctrl+,) can open over it while it downloads, and installing
/// then would quit App Studio in the middle of `serverpod create` or a
/// tool install. A covered dialog drops its download and goes back to the
/// offer, as a cancel does.
InstallUpdate _installer(
  LinuxUpdater updater,
  Future<void> Function() quit,
  ModalRoute<Object?>? dialog,
) => (item, {required onProgress, required cancellation}) async {
  final verified = await updater.download(
    item,
    onProgress: onProgress,
    cancellation: cancellation,
  );
  if (verified == null) return false;
  // The dialog may have gone, or been covered, while the signature was
  // checked.
  if (cancellation.isCancelled || !(dialog?.isCurrent ?? false)) {
    await updater.discard(verified.path);
    return false;
  }
  await updater.install(verified);
  await quit();
  return true;
};

/// The same quit as File → Quit, teardown included; the new AppImage starts
/// once this process has ended.
Future<void> _quitApp() async {
  await ServicesBinding.instance.exitApplication(AppExitType.cancelable);
}
