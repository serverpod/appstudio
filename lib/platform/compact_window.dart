import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Corner of the compact preview window being resized, in UI (top-left origin)
/// terms. The native side translates to screen coordinates.
enum CompactResizeCorner { topLeft, topRight, bottomLeft, bottomRight }

/// Geometry contract for the compact (minimized phone) window.
///
/// The window keeps the phone frame's aspect ratio through every resize, but
/// the chrome around the frame — the transparent margin and the control bar
/// below it — is fixed-size, so the ratio holds on the *content* rather than
/// the window: `height = chromeHeight + (width - chromeWidth) * aspectHeight /
/// aspectWidth`. The native side stores this and applies it both when resizing
/// from a corner and when the orientation flips while compact.
class CompactWindowGeometry {
  const CompactWindowGeometry({
    required this.aspectWidth,
    required this.aspectHeight,
    required this.chromeWidth,
    required this.chromeHeight,
    required this.minWidth,
  });

  /// Aspect of the phone frame (logical px), not of the whole window.
  final double aspectWidth;
  final double aspectHeight;

  /// Fixed horizontal chrome: the transparent margins beside the frame.
  final double chromeWidth;

  /// Fixed vertical chrome: margins plus the control bar and its gap.
  final double chromeHeight;

  /// Smallest window width a corner drag may reach.
  final double minWidth;

  Map<String, double> toArgs() => {
        'aspectWidth': aspectWidth,
        'aspectHeight': aspectHeight,
        'chromeWidth': chromeWidth,
        'chromeHeight': chromeHeight,
        'minWidth': minWidth,
      };
}

/// Native window control for the compact preview mode.
///
/// An interface rather than the channel directly so [PreviewModeController]
/// can be tested without a platform, the same narrow split `ToolsView` and
/// `FullRestartView` use.
abstract class CompactWindowPlatform {
  /// Whether this platform has a compact window at all. Only macOS does so
  /// far; elsewhere minimizing a phone view behaves as minimizing the
  /// desktop view does — the window stays, the shell's chrome goes.
  bool get supportsCompactWindow;

  /// Strips the window to a borderless, transparent one sized to [geometry].
  Future<void> enterCompact(CompactWindowGeometry geometry);

  /// Re-applies [geometry] to an already-compact window (orientation flip),
  /// keeping the current window height.
  Future<void> updateGeometry(CompactWindowGeometry geometry);

  /// Restores the window state saved by [enterCompact].
  Future<void> exitCompact();

  /// Hands the in-flight mouse drag to the OS to move the window.
  Future<void> startDrag();

  /// Starts a native aspect-locked resize from [corner], tracked until the
  /// mouse is released.
  Future<void> startResize(CompactResizeCorner corner);

  /// Shows the diagonal resize cursor for [corner] — the macOS engine maps no
  /// diagonal `SystemMouseCursors`, so the affordance has to come from AppKit.
  /// One-shot: the framework's next cursor change simply paints over it.
  Future<void> showResizeCursor(CompactResizeCorner corner);
}

/// The real thing: `dev.serverpod.appstudio/window`, handled by
/// `MainFlutterWindow.swift`.
class CompactWindowChannel implements CompactWindowPlatform {
  static const MethodChannel _channel =
      MethodChannel('dev.serverpod.appstudio/window');

  /// The channel has a native side on macOS only (Windows: a later phase of
  /// the port, `specs/windows_port.md`).
  @override
  bool get supportsCompactWindow =>
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Future<void> enterCompact(CompactWindowGeometry geometry) =>
      _channel.invokeMethod<void>('enterCompact', geometry.toArgs());

  @override
  Future<void> updateGeometry(CompactWindowGeometry geometry) =>
      _channel.invokeMethod<void>('updateCompactGeometry', geometry.toArgs());

  @override
  Future<void> exitCompact() => _channel.invokeMethod<void>('exitCompact');

  @override
  Future<void> startDrag() => _channel.invokeMethod<void>('startDrag');

  @override
  Future<void> startResize(CompactResizeCorner corner) =>
      _channel.invokeMethod<void>('startResize', {'corner': corner.name});

  @override
  Future<void> showResizeCursor(CompactResizeCorner corner) =>
      _channel.invokeMethod<void>('showResizeCursor', {'corner': corner.name});
}
