import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../landing_scaffold.dart';
import 'toolchain_setup_dialog.dart';
import 'tools_view.dart';

/// First-run gate: the whole screen until the required tools are installed.
///
/// It used to be the setup dialog floating over the start page, which offered a
/// New Project button that could not work — nothing can be created or opened
/// without a Flutter SDK and the Serverpod CLI. Owning the screen means there is
/// only ever one thing to do.
///
/// The body is a spinner and nothing else. Every number in the plan — which
/// versions, how many bytes — comes from the bucket, so the dialog is not raised
/// until [ToolsView.preflight] has answered; raising it first and filling it in
/// afterwards is what made a slow network look like a stuck dialog.
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
    // Pushing a route from inside a build is illegal, and the first preflight
    // may finish fast enough to try.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_drive()));
  }

  /// Preflight, then either the plan or the failure, until the toolchain is
  /// complete or the user quits.
  ///
  /// Both dialogs block on the user, so the loop cannot spin: it turns over only
  /// when someone presses "Try again", or when a download finished and left
  /// something still missing.
  Future<void> _drive() async {
    while (mounted && widget.toolchains.inventory.installable.isNotEmpty) {
      final error = await widget.toolchains.preflight();
      if (!mounted) return;
      if (error != null) {
        await showToolchainSetupErrorDialog(context, message: error);
        continue;
      }
      // The preflight re-resolves against whatever manifest it found, which can
      // leave nothing to install. The plan dialog only closes itself once an
      // install has run, so raising an empty one would strand a modal over the
      // shell that main.dart has already switched to.
      if (widget.toolchains.inventory.installable.isEmpty) return;
      await showToolchainSetupDialog(context, toolchains: widget.toolchains);
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
