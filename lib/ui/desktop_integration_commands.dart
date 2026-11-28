import 'dart:ui' show AppExitType;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shad/shad.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/host.dart';
import '../platform/linux/desktop_integration.dart';
import '../widgets/app_dialog.dart';
import 'add_to_applications_dialog.dart';

/// Set by "Don't ask again", and by Remove from Applications.
const kAddToApplicationsDeclinedKey = 'linux.add_to_applications_declined';

/// Asks [maybeOfferAddToApplications] at most once per run, and only on
/// Linux. The app calls [offerOnce] from two places, the first start page
/// and the end of setup, and whichever comes first asks.
class AddToApplicationsOffer {
  AddToApplicationsOffer(this.integration, {HostPlatform? host})
    : host = host ?? currentHost;

  final DesktopIntegrationController integration;
  final HostPlatform host;
  bool _offered = false;

  Future<void> offerOnce(
    BuildContext context, {
    required bool Function() onStartPage,
  }) async {
    if (!host.isLinux || _offered) return;
    _offered = true;
    await maybeOfferAddToApplications(
      context,
      integration,
      onStartPage: onStartPage,
    );
  }
}

/// The question on start, once the start page shows: when App Studio runs as
/// an AppImage nobody has added to the app menu yet, whether to add it,
/// unless the user said not to ask again. When App Studio added another copy,
/// whether to replace that one (this one is newer) or open it (it is).
///
/// [onStartPage] is checked again right before a dialog goes up: the checks
/// read the disk, and a project opened meanwhile must not get the question
/// over it. [quit] is File → Quit's teardown and exit, replaceable in tests.
Future<void> maybeOfferAddToApplications(
  BuildContext context,
  DesktopIntegrationController integration, {
  required bool Function() onStartPage,
  @visibleForTesting Future<void> Function()? quit,
}) async {
  await integration.refresh();
  if (integration.status == DesktopIntegrationStatus.addedByAppStudio) {
    if (context.mounted) {
      await _offerForOtherCopy(
        context,
        integration,
        onStartPage: onStartPage,
        quit: quit ?? _quit,
      );
    }
    return;
  }
  if (integration.status != DesktopIntegrationStatus.notAdded) return;
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(kAddToApplicationsDeclinedKey) ?? false) return;
  final folder = await integration.integration.currentFolder();
  final keepsOriginal = await integration.integration.keepsOriginal();
  final replaced = await integration.integration.replacesAnotherFile()
      ? integration.integration.addedAppImagePath
      : null;
  if (!context.mounted || !onStartPage()) return;
  final answer = await _showAddDialog(
    context,
    integration,
    fromMenu: false,
    currentFolder: folder,
    keepsOriginal: keepsOriginal,
    replacedFile: replaced,
  );
  if (answer == AddToApplicationsAnswer.never) {
    await prefs.setBool(kAddToApplicationsDeclinedKey, true);
  }
}

/// Help → Add to Applications.
Future<void> addToApplications(
  BuildContext context,
  DesktopIntegrationController integration,
) async {
  await integration.refresh();
  if (integration.status != DesktopIntegrationStatus.notAdded) return;
  final folder = await integration.integration.currentFolder();
  final keepsOriginal = await integration.integration.keepsOriginal();
  final replaced = await integration.integration.replacesAnotherFile()
      ? integration.integration.addedAppImagePath
      : null;
  if (!context.mounted) return;
  await _showAddDialog(
    context,
    integration,
    fromMenu: true,
    currentFolder: folder,
    keepsOriginal: keepsOriginal,
    replacedFile: replaced,
  );
}

Future<AddToApplicationsAnswer?> _showAddDialog(
  BuildContext context,
  DesktopIntegrationController integration, {
  required bool fromMenu,
  required String? currentFolder,
  required bool keepsOriginal,
  required String? replacedFile,
}) async {
  final answer = await showAppDialog<AddToApplicationsAnswer>(
    context: context,
    // Not now is the way out; a stray click beside the dialog must not throw
    // away a ticked "Don't ask again", nor close it while Add runs.
    barrierDismissible: false,
    builder: (context) => AddToApplicationsDialog(
      onAdd: integration.add,
      currentFolder: currentFolder,
      keepsOriginal: keepsOriginal,
      replacedFile: replacedFile,
      offerDontAskAgain: !fromMenu,
    ),
  );
  if (answer == AddToApplicationsAnswer.added && context.mounted) {
    ShadToaster.maybeOf(
      context,
    )?.show(const ShadToast(title: Text('Added to your applications')));
  }
  return answer;
}

/// Help → Remove from Applications.
Future<void> removeFromApplications(
  BuildContext context,
  DesktopIntegrationController integration,
) async {
  await integration.refresh();
  final appImage = integration.integration.addedAppImagePath;
  if (integration.status != DesktopIntegrationStatus.addedByAppStudio ||
      appImage == null ||
      !context.mounted) {
    return;
  }
  final confirmed = await showAppDialog<bool>(
    context: context,
    builder: (context) => RemoveFromApplicationsDialog(appImagePath: appImage),
  );
  if (confirmed != true || !context.mounted) return;
  final toaster = ShadToaster.maybeOf(context);
  // Before the removal, so a removal that fails halfway — the entry gone, an
  // icon left — still does not ask again on the next start.
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(kAddToApplicationsDeclinedKey, true);
  try {
    await integration.remove();
  } catch (e) {
    toaster?.show(
      ShadToast.destructive(
        title: const Text('Could not remove App Studio from your applications'),
        description: Text('$e'),
      ),
    );
    return;
  }
  toaster?.show(const ShadToast(title: Text('Removed from your applications')));
}

/// No "Don't ask again" here: the question is about this one file, and only
/// comes up when the user starts a second copy by hand.
Future<void> _offerForOtherCopy(
  BuildContext context,
  DesktopIntegrationController integration, {
  required bool Function() onStartPage,
  required Future<void> Function() quit,
}) async {
  final desktop = integration.integration;
  final copy = await desktop.otherCopy();
  if (copy == null) return;
  final folder = await desktop.currentFolder();
  // Only the Replace question names the folder this copy is in.
  final keepsOriginal = copy.runningIsNewer && await desktop.keepsOriginal();
  if (!context.mounted || !onStartPage()) return;
  final toaster = ShadToaster.maybeOf(context);

  if (copy.runningIsNewer) {
    final replaced = await showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ReplaceAddedCopyDialog(
        running: copy.running,
        added: copy.added,
        onReplace: integration.add,
        currentFolder: folder,
        keepsOriginal: keepsOriginal,
      ),
    );
    if (replaced == true) {
      toaster?.show(
        ShadToast(
          title: Text(
            'App Studio ${copyVersionLabel(copy.running, copy.added)} '
            'is in your applications',
          ),
        ),
      );
    }
    return;
  }

  if (copy.runningIsOlder) {
    final open = await showAppDialog<bool>(
      context: context,
      builder: (context) =>
          OlderCopyDialog(running: copy.running, added: copy.added),
    );
    if (open != true) return;
    try {
      await desktop.openAddedCopyAfterExit();
    } catch (e) {
      toaster?.show(
        ShadToast.destructive(
          title: const Text('Could not open the newer App Studio'),
          description: Text('$e'),
        ),
      );
      return;
    }
    // The newer copy starts once this process is gone.
    await quit();
  }
}

/// The same quit as File → Quit, teardown included.
Future<void> _quit() async {
  await ServicesBinding.instance.exitApplication(AppExitType.cancelable);
}
