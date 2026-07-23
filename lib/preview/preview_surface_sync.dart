import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_cef/webview_cef.dart';

/// Keeps the embedded Flutter web preview in sync when panel constraints change.
class PreviewSurfaceSync extends StatefulWidget {
  const PreviewSurfaceSync({
    super.key,
    required this.controller,
    required this.child,
    this.explicitSize,
  });

  final WebViewController controller;
  final Widget child;

  /// When set (phone preview), pushes this exact viewport to CEF instead of
  /// waiting for layout measurement through [FittedBox].
  final Size? explicitSize;

  @override
  State<PreviewSurfaceSync> createState() => _PreviewSurfaceSyncState();
}

class _PreviewSurfaceSyncState extends State<PreviewSurfaceSync>
    with WidgetsBindingObserver {
  Size? _lastConstraints;
  int _syncGeneration = 0;
  bool _syncScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleSync(burstFrames: widget.explicitSize != null ? 2 : 0);
  }

  @override
  void didUpdateWidget(covariant PreviewSurfaceSync oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.explicitSize != widget.explicitSize) {
      _scheduleSync(burstFrames: 3);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _scheduleSync();
  }

  void _scheduleSync({int burstFrames = 0}) {
    _syncGeneration++;
    final generation = _syncGeneration;

    if (_syncScheduled && burstFrames == 0) return;
    _syncScheduled = true;

    Future<void> run() async {
      if (!mounted || generation != _syncGeneration) return;
      await _syncPreviewSurface(force: burstFrames > 0);
    }

    void scheduleFrame(int remaining) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _syncScheduled = remaining > 1;
        if (!mounted || generation != _syncGeneration) return;
        unawaited(run());
        if (remaining > 1) {
          scheduleFrame(remaining - 1);
        }
      });
    }

    final frames = burstFrames > 0 ? burstFrames + 1 : 1;
    scheduleFrame(frames);
  }

  Future<void> _syncPreviewSurface({bool force = false}) async {
    final controller = widget.controller;
    if (!controller.value || !context.mounted) return;

    final explicitSize = widget.explicitSize;
    if (explicitSize != null) {
      final dpi = MediaQuery.devicePixelRatioOf(context);
      await controller.setSurfaceSize(
        explicitSize,
        devicePixelRatio: dpi,
      );
      return;
    }

    await controller.syncSurfaceSize(force: force);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (widget.explicitSize == null) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          if (_lastConstraints != size) {
            _lastConstraints = size;
            _scheduleSync();
          }
        }
        return widget.child;
      },
    );
  }
}

/// Runs a short burst of frame syncs after a display-mode or orientation change.
Future<void> burstSyncPreviewSurface(
  WebViewController controller, {
  required BuildContext context,
  Size? phoneViewport,
  int frames = 3,
  bool Function()? isCancelled,
}) async {
  if (!controller.value || !context.mounted) return;

  Future<void> syncOnce({required bool force}) async {
    if (!controller.value || !context.mounted || (isCancelled?.call() ?? false)) {
      return;
    }
    final dpi = MediaQuery.devicePixelRatioOf(context);
    if (phoneViewport != null) {
      await controller.setSurfaceSize(
        phoneViewport,
        devicePixelRatio: dpi,
      );
    } else {
      await controller.syncSurfaceSize(force: force);
    }
  }

  // Defer the first sync until after the current frame so inherited widgets
  // like [MediaQuery] are fully available (e.g. after setState rebuild).
  await WidgetsBinding.instance.endOfFrame;
  if (isCancelled?.call() ?? false || !context.mounted) return;

  await syncOnce(force: true);

  for (var i = 0; i < frames; i++) {
    if (isCancelled?.call() ?? false || !context.mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    if (isCancelled?.call() ?? false || !context.mounted) return;
    await syncOnce(force: i == frames - 1);
  }
}
