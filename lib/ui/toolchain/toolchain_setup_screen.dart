import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../landing_scaffold.dart';
import 'toolchain_notices.dart';
import 'toolchain_setup_dialog.dart';
import 'tools_view.dart';

/// First-run gate: the whole screen until the tools are in place.
///
/// It used to be the setup dialog floating over the start page, which offered a
/// New Project button that could not work — nothing can be created or opened
/// without a Flutter SDK and the Serverpod CLI. Owning the screen means there is
/// only ever one thing to do.
///
/// The body is a spinner and nothing else; every step is a dialog over it.
class ToolchainSetupScreen extends StatefulWidget {
  const ToolchainSetupScreen({super.key, required this.toolchains});

  final ToolsView toolchains;

  @override
  State<ToolchainSetupScreen> createState() => _ToolchainSetupScreenState();
}

class _ToolchainSetupScreenState extends State<ToolchainSetupScreen> {
  @override
  void initState() {
    super.initState();
    // Pushing a route from inside a build is illegal, and the first step may
    // be ready fast enough to try.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_drive()));
  }

  /// Every step setup can take, in order, until nothing is left or the user
  /// quits:
  ///
  ///  1. Tools an earlier build installed into Application Support: say that
  ///     this is changing, then remove them.
  ///  2. A Flutter the user installed that is too old: ask them to update it.
  ///     It comes before the install, because the Serverpod CLI is installed
  ///     with that Flutter's `dart`.
  ///  3. Everything App Studio can install itself: look up the versions, then
  ///     show the plan.
  ///
  /// Every dialog blocks on the user, so the loop cannot spin: it turns over
  /// only when someone presses a button, or an install left something to do.
  Future<void> _drive() async {
    final toolchains = widget.toolchains;
    while (true) {
      if (!mounted || !toolchains.inventory.needsSetup) return;
      if (toolchains.inventory.legacyInstallFound) {
        await showLegacyInstallNotice(context);
        if (!mounted) return;
        final error = await toolchains.removeLegacyInstall();
        if (!mounted) return;
        if (error != null) {
          await showToolchainSetupErrorDialog(
            context,
            title: 'Could not remove the old tools',
            message: error,
          );
        }
        continue;
      }

      if (toolchains.inventory.needsManualUpdate.isNotEmpty) {
        await showManualUpdateDialog(context, toolchains: toolchains);
        continue;
      }

      final error = await toolchains.preflight();
      if (!mounted) return;
      if (error != null) {
        await showToolchainSetupErrorDialog(context, message: error);
        continue;
      }
      // The plan dialog only closes itself once an install has run, so raising
      // an empty one would strand a modal over the shell that main.dart has
      // already switched to.
      if (toolchains.inventory.installable.isEmpty) return;
      await showToolchainSetupDialog(context, toolchains: toolchains);
    }
  }

  @override
  Widget build(BuildContext context) {
    return const LandingScaffold(
      // White, not a theme colour: the backdrop is a fixed brand image in both
      // themes, and the spinner sits over its saturated middle, where
      // `primary` (brand blue) all but disappears.
      child: Center(child: ShadSpinner(color: Colors.white)),
    );
  }
}
