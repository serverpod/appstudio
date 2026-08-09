import 'package:flutter/material.dart';
import 'package:flutter/widget_previews.dart';

import '../ui/toolchain/toolchain_setup_dialog.dart';
import '../ui/toolchain/toolchain_setup_screen.dart';
import 'preview_app.dart';
import 'preview_data.dart';

/// Widget previews for the first-run toolchain install.
///
/// Run with `make previews`.
///
/// This is the flow that is hardest to look at for real: it only happens on a
/// machine with no toolchain, it takes a 662 MB download to reach the middle of
/// it, and the failure states need a broken network. Everything here is driven
/// by the fakes in `preview_data.dart`, which implement the same [ToolsView]
/// interface the app uses, so nothing can drift from what ships without the
/// analyzer noticing.
///
/// Every preview is emitted twice, light and dark — see [BrightnessPreview].

/// Emits the annotated preview once per brightness.
///
/// The two are worth seeing side by side rather than behind the scaffold's
/// toggle: this dialog is the first thing a new user sees, and it is the one
/// surface where a missed colour cannot be worked around by the user.
final class BrightnessPreview extends MultiPreview {
  const BrightnessPreview({required this.name, this.size = _kDialogSize});

  final String name;

  /// The viewport each copy is rendered into. Dialogs size themselves inside
  /// it; a full-screen preview needs it to have a window to lay out against.
  final Size size;

  /// The scaffold calls this from `main()`, which is the shallowest frame we
  /// can reach — and that is the whole reason [warmThemes] is called here
  /// rather than in [previewShell]. Read its doc before moving it: build the
  /// theme lazily from inside a widget build instead and every preview in this
  /// file dies with a stack overflow.
  @override
  List<Preview> transform() {
    warmThemes();
    return super.transform();
  }

  @override
  List<Preview> get previews => <Preview>[
    Preview(
      group: 'Toolchain setup',
      name: '$name — light',
      brightness: Brightness.light,
      size: size,
    ),
    Preview(
      group: 'Toolchain setup',
      name: '$name — dark',
      brightness: Brightness.dark,
      size: size,
    ),
  ];
}

/// Wide enough that the plan table's version badges and sizes are not the
/// thing being tested, tall enough for the longest plan plus the opt-in.
const _kDialogSize = Size(720, 560);

/// A full window, so the gradient is on screen at something like its real
/// proportions.
const _kScreenSize = Size(1000, 700);

// --- The plan ---------------------------------------------------------------

/// First run on a clean Mac: nothing found anywhere, so every tool is a
/// download. The common case, and the one the copy is written for.
@BrightnessPreview(name: 'Plan — nothing installed')
Widget toolchainSetupPlan() => previewShell(
  ToolchainSetupDialog(toolchains: FakeToolsView(inventory: emptyInventory)),
);

/// The awkward middle: a host Git we can reuse, a Serverpod CLI too old to use
/// (so the row reads `4.0.0-beta.0 → 4.0.0-beta.1`), and a missing OpenCode.
/// This is the only state that shows the "Installed" badge and the replacing
/// form of the version badge at the same time.
@BrightnessPreview(name: 'Plan — partly satisfied')
Widget toolchainSetupPlanMixed() => previewShell(
  ToolchainSetupDialog(toolchains: FakeToolsView(inventory: mixedInventory)),
);

/// A download that died partway. The dialog comes back to the plan with the
/// banner over it, because the remaining tools are still the thing to do.
@BrightnessPreview(name: 'Plan — after a failed download')
Widget toolchainSetupPlanError() => previewShell(
  ToolchainSetupDialog(
    toolchains: FakeToolsView(
      inventory: emptyInventory,
      installError:
          'Download failed: connection closed before the '
          'archive finished (Flutter SDK).',
    ),
  ),
);

// --- The install ------------------------------------------------------------

/// Mid-download, with Flutter in flight and the Serverpod CLI queued behind it.
/// Cancel is live here — this is the last point where there is anything to
/// call off.
@BrightnessPreview(name: 'Installing — downloading')
Widget toolchainSetupDownloading() => previewShell(
  ToolchainSetupDialog(
    toolchains: FakeToolsView(
      inventory: emptyInventory,
      progress: downloadingProgress,
      isInstalling: true,
      isBusy: true,
    ),
  ),
);

/// The tail: every byte has landed and the re-probe and the shell `PATH` write
/// are still out. The plan must *not* come back here — it is the last thing
/// seen before the dialog closes, and it reads as the install being discarded.
/// Cancel dims rather than disappearing, because there is nothing left to stop.
@BrightnessPreview(name: 'Installing — finishing up')
Widget toolchainSetupFinishing() => previewShell(
  ToolchainSetupDialog(
    toolchains: FakeToolsView(
      inventory: emptyInventory,
      progress: finishingProgress,
      isInstalling: true,
      isBusy: true,
    ),
  ),
);

// --- Preflight --------------------------------------------------------------

/// No route to the bucket, so there is no plan to show. Try again and Quit are
/// the only honest choices: nothing downstream works without these tools.
@BrightnessPreview(name: 'Preflight failed')
Widget toolchainSetupPreflightError() => previewShell(
  const ToolchainSetupErrorDialog(
    message:
        'Could not reach the download server for Flutter SDK and '
        'Serverpod CLI. Check your internet connection and try again.',
  ),
);

/// The screen the dialogs sit on, held at the spinner it shows while the plan
/// is still being fetched. White on purpose: `primary` all but disappears
/// against the saturated middle of the gradient.
@BrightnessPreview(name: 'Setup screen — loading', size: _kScreenSize)
Widget toolchainSetupScreenLoading() => previewShell(
  ToolchainSetupScreen(
    toolchains: FakeToolsView(
      inventory: emptyInventory,
      preflightDelay: const Duration(days: 1),
    ),
  ),
);
