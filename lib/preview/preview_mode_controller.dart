import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/compact_window.dart';
import 'preview_device.dart';

/// Transparent margin around the phone frame in the compact window — room for
/// the frame's own drop shadow, which would otherwise clip at the window edge.
/// The shadow scales with the frame (it is painted inside the `FittedBox`), so
/// the margin carries slack beyond the shadow's ~33px resting extent.
const kCompactFrameMargin = 40.0;

/// Gap between the frame and the control bar below it.
const kCompactBarGap = 10.0;

/// Height reserved for the compact control bar row.
const kCompactBarHeight = 44.0;

/// Smallest window width a compact resize may reach.
///
/// Set by the control bar under the frame, which is a fixed row of controls
/// (~222 px) and has to fit with room to spare — at 240 it overflowed, and the
/// portrait frame was a 160 px sliver. 300 still overflowed while resizing in
/// the app, so 320, which keeps the frame at least 240 px wide.
/// `test/preview/compact_control_bar_test.dart` measures the bar against this,
/// but in a test window; the app needed more.
const kCompactMinWindowWidth = 320.0;

/// The window geometry for a phone view mode's compact window.
CompactWindowGeometry compactWindowGeometry(PreviewViewMode mode) {
  final frame = previewPhoneFrameSize(mode.orientation);
  return CompactWindowGeometry(
    aspectWidth: frame.width,
    aspectHeight: frame.height,
    chromeWidth: kCompactFrameMargin * 2,
    chromeHeight: kCompactFrameMargin * 2 + kCompactBarGap + kCompactBarHeight,
    minWidth: kCompactMinWindowWidth,
  );
}

/// Owns the preview's view mode, previewed-app brightness and the minimized
/// state — lifted out of `PreviewPaneState` because minimizing reshapes the
/// whole window: the shell drops its toolbar, `ShadApp` drops its opaque
/// background, and the native window goes borderless. All of those live above
/// the preview pane.
///
/// Minimized means two different things by view mode, and this is the one
/// place that policy lives:
/// - **Phone**: [compactWindow] — the window is stripped to the bare frame
///   plus a control bar, made transparent, and moved/resized by dragging the
///   frame itself.
/// - **Desktop**: only the shell's toolbar is hidden; the window is untouched.
class PreviewModeController extends ChangeNotifier {
  PreviewModeController({required this._window});

  final CompactWindowPlatform _window;

  PreviewViewMode _viewMode = PreviewViewMode.phonePortrait;
  Brightness _previewBrightness = Brightness.light;
  bool _minimized = false;

  PreviewViewMode get viewMode => _viewMode;
  Brightness get previewBrightness => _previewBrightness;
  bool get minimized => _minimized;

  /// Whether the native window is (or should be) in its compact form —
  /// borderless and phone-shaped, transparent around the frame on macOS.
  /// Minimized desktop keeps the normal window, and so does every view on a
  /// platform without a compact window.
  bool get compactWindow =>
      _window.supportsCompactWindow &&
      _minimized &&
      _viewMode.displayMode == PreviewDisplayMode.phone;

  void setViewMode(PreviewViewMode mode) {
    if (_viewMode == mode) return;
    final wasCompact = compactWindow;
    _viewMode = mode;
    final isCompact = compactWindow;
    if (wasCompact && !isCompact) {
      // Minimized phone → minimized desktop: the window comes back, the
      // toolbar stays hidden.
      _run(_window.exitCompact());
    } else if (!wasCompact && isCompact) {
      _run(_window.enterCompact(compactWindowGeometry(mode)));
    } else if (isCompact) {
      // Portrait ↔ landscape while compact.
      _run(_window.updateGeometry(compactWindowGeometry(mode)));
    }
    notifyListeners();
  }

  void setPreviewBrightness(Brightness brightness) {
    if (_previewBrightness == brightness) return;
    _previewBrightness = brightness;
    notifyListeners();
  }

  void toggleMinimized() => _minimized ? expand() : minimize();

  void minimize() {
    if (_minimized) return;
    _minimized = true;
    if (compactWindow) {
      _run(_window.enterCompact(compactWindowGeometry(_viewMode)));
    }
    notifyListeners();
  }

  /// Back to the full window. Safe to call when not minimized — opening or
  /// closing a project routes through here so a compact window can never
  /// outlive the preview it was framing.
  void expand() {
    if (!_minimized) return;
    final wasCompact = compactWindow;
    _minimized = false;
    if (wasCompact) {
      _run(_window.exitCompact());
    }
    notifyListeners();
  }

  void startWindowDrag() => _run(_window.startDrag());

  void startWindowResize(CompactResizeCorner corner) =>
      _run(_window.startResize(corner));

  /// Shows the native diagonal resize cursor for [corner]. Native because the
  /// macOS engine has no diagonal cursors — `resizeUpLeftDownRight` falls back
  /// to the arrow. Deferred a microtask so it lands *after* the framework's
  /// own `activateSystemCursor` for this pointer update, which would otherwise
  /// overwrite it with that arrow.
  void showResizeCursor(CompactResizeCorner corner) {
    scheduleMicrotask(() => _run(_window.showResizeCursor(corner)));
  }

  /// Native window calls are fire-and-forget: a window that failed to go
  /// transparent is a cosmetic bug, not one worth an unhandled error.
  void _run(Future<void> future) {
    unawaited(future.catchError((Object e) {
      debugPrint('Compact window call failed: $e');
    }));
  }
}
