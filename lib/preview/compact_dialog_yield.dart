import 'dart:async';

import 'package:flutter/widgets.dart';

import 'preview_mode_controller.dart';

/// Expands the compact preview window before anything opens over it.
///
/// A route pushed while the window is the bare phone frame has nowhere to go:
/// dialogs are sized for the full shell, so they overflow the phone-sized
/// window — some of them breaking its layout outright — and their blurred
/// barrier is drawn over a transparent window, which blurs nothing. The menu
/// bar stays fully live in compact mode (Settings, About, Open Recent…), so
/// this cannot be prevented at the sources; the navigator is the one funnel
/// every dialog passes through.
///
/// Expanding is deferred a microtask: observers are called inside the
/// navigator's own mutation, and the expand lands before the route's first
/// frame either way — the dialog never paints over the transparent window.
///
/// Deliberately one-way. Re-minimizing when the dialog closes sounds nicer but
/// collides with everything else that pops routes (project switches clear the
/// stack, uninstall replaces the screen), and guessing wrong re-enters a
/// compact window the user no longer wants. One click re-minimizes.
class CompactDialogYield extends NavigatorObserver {
  CompactDialogYield(this._previewMode);

  final PreviewModeController _previewMode;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // `home` itself has no previous route and is exactly the compact content.
    if (previousRoute == null) return;
    if (!_previewMode.compactWindow) return;
    scheduleMicrotask(_previewMode.expand);
  }
}
