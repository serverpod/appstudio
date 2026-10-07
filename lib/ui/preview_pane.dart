import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shad/shad.dart';
import 'package:webview_cef/webview_cef.dart';

import '../platform/compact_window.dart';
import '../preview/preview_bootstrap.dart';
import '../preview/preview_cache_purge.dart';
import '../preview/preview_device.dart';
import '../preview/preview_hero_gradient.dart';
import '../preview/preview_mode_controller.dart';
import '../preview/preview_status_overlay.dart';
import '../preview/registration_code_toast.dart';
import '../preview/preview_surface_sync.dart';
import '../preview/preview_theme.dart';
import '../process/serverpod_process.dart';
import 'preview_header_bars.dart';

/// The project the shared CEF profile last served.
///
/// The profile behind the preview (HTTP cache, localStorage, service workers,
/// cookies) is global to the CEF request context — it survives the per-project
/// webview. Each run of the app is served on whatever free port `flutter run
/// -d web-server` picked, so two projects usually get different origins, but
/// ports are reused and nothing guarantees it; without a clear, the next
/// project's first load could be answered out of the previous project's
/// state. Module-level because the pane's State unmounts when a project
/// closes; the profile does not.
String? _cefProfileProjectPath;

class PreviewPane extends StatefulWidget {
  const PreviewPane({
    super.key,
    required this.process,
    required this.mode,
    this.gradientAnimating = false,
  });

  final ServerpodProcessController process;
  final PreviewModeController mode;
  final bool gradientAnimating;

  @override
  State<PreviewPane> createState() => PreviewPaneState();
}

class PreviewPaneState extends State<PreviewPane> {
  WebViewController? _controller;
  bool _initializing = false;
  bool _managerReady = false;
  String? _error;
  int _lastReloadToken = 0;
  Brightness? _appliedBrightness;

  /// The URL the current webview was created for. The runner publishes the
  /// app's URL, and an app relaunched by it can come back on another port.
  Uri? _loadedUrl;

  late PreviewViewMode _lastViewMode;
  late Brightness _lastModeBrightness;
  int _surfaceSyncGeneration = 0;
  int _revealGeneration = 0;

  bool get _shouldLoad => widget.process.previewReady;

  Future<void> reload() async {
    if (!_shouldLoad) return;
    final controller = _controller;
    if (controller == null || !controller.value) {
      await _ensureWebView();
      return;
    }
    final revealGeneration = ++_revealGeneration;
    try {
      // Hard reload, and it has to be hard on both sides: a service worker or a
      // Cache Storage entry outlives the navigation and would answer the new
      // document out of the previous build, and a plain navigation re-serves
      // the cached `main.dart.js` — so a rebuilt app would look unchanged.
      await _purgePageCaches(controller);
      if (!mounted || revealGeneration != _revealGeneration) return;
      await controller.reloadIgnoreCache();
      await _waitForFlutterMain(
        controller,
        isCancelled: () =>
            !mounted ||
            _controller != controller ||
            revealGeneration != _revealGeneration,
      );
      if (!mounted || revealGeneration != _revealGeneration) return;
      // The theme shim is injected at load start with the brightness captured
      // when the webview was created, so a reload resets it — re-apply.
      _appliedBrightness = null;
      await _applyPreviewTheme(widget.mode.previewBrightness);
      if (!mounted || revealGeneration != _revealGeneration) return;
      widget.process.markPreviewLive();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void initState() {
    super.initState();
    widget.process.addListener(_onProcessChanged);
    _lastViewMode = widget.mode.viewMode;
    _lastModeBrightness = widget.mode.previewBrightness;
    widget.mode.addListener(_onModeChanged);
    if (_shouldLoad) {
      unawaited(_ensureWebView());
    }
  }

  @override
  void didUpdateWidget(covariant PreviewPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.process != widget.process) {
      oldWidget.process.removeListener(_onProcessChanged);
      widget.process.addListener(_onProcessChanged);
    }
    if (oldWidget.mode != widget.mode) {
      oldWidget.mode.removeListener(_onModeChanged);
      widget.mode.addListener(_onModeChanged);
      _onModeChanged();
    }
  }

  void _onProcessChanged() {
    if (!mounted) return;

    final shouldLoad = widget.process.previewReady;
    final reloadToken = widget.process.previewReloadToken;

    if (!shouldLoad && _controller != null) {
      _tearDownWebView();
      return;
    }
    if (shouldLoad &&
        _controller != null &&
        !_initializing &&
        widget.process.previewUrl != _loadedUrl) {
      _tearDownWebView();
      unawaited(_ensureWebView());
      return;
    }
    if (shouldLoad && _controller == null && !_initializing) {
      unawaited(_ensureWebView());
      return;
    }
    if (shouldLoad &&
        reloadToken != _lastReloadToken &&
        reloadToken > 0 &&
        _controller != null) {
      _lastReloadToken = reloadToken;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) reload();
      });
    }
    setState(() {});
  }

  /// View mode and brightness live in the controller now; this reacts to them
  /// exactly the way the old local setters did.
  void _onModeChanged() {
    if (!mounted) return;
    final mode = widget.mode;
    if (mode.viewMode != _lastViewMode) {
      _lastViewMode = mode.viewMode;
      _requestSurfaceSync();
    }
    if (mode.previewBrightness != _lastModeBrightness) {
      _lastModeBrightness = mode.previewBrightness;
      unawaited(_applyPreviewTheme(mode.previewBrightness));
    }
    setState(() {});
  }

  void _requestSurfaceSync() {
    unawaited(_burstSyncPreviewSurface());
  }

  Future<void> _burstSyncPreviewSurface() async {
    final controller = _controller;
    if (controller == null || !controller.value || !mounted) return;

    _surfaceSyncGeneration++;
    final generation = _surfaceSyncGeneration;

    final viewMode = widget.mode.viewMode;
    final phoneViewport = viewMode.displayMode == PreviewDisplayMode.phone
        ? previewPhoneViewport(viewMode.orientation)
        : null;

    await burstSyncPreviewSurface(
      controller,
      context: context,
      phoneViewport: phoneViewport,
      isCancelled: () => !mounted || generation != _surfaceSyncGeneration,
    );
  }

  Future<void> _ensureWebView() async {
    if (!_shouldLoad || _initializing) return;
    _initializing = true;
    _error = null;
    if (mounted) setState(() {});

    try {
      if (!_managerReady) {
        await WebviewManager().initialize(
          userAgent: 'AppStudio/1.0 (Chromium CEF)',
        );
        _managerReady = true;
      }

      await _disposeController();
      _appliedBrightness = null;

      final isDark = widget.mode.previewBrightness == Brightness.dark;
      final scripts = InjectUserScripts()
        ..add(
          UserScript(
            previewThemeShimScript(isDark: isDark),
            ScriptInjectTime.LOAD_START,
          ),
        )
        ..add(
          UserScript(previewBootstrapScript, ScriptInjectTime.LOAD_START),
        );

      final controller = WebviewManager().createWebView(
        loading: const SizedBox.shrink(),
        injectUserScripts: scripts,
      );
      _controller = controller;
      controller.addListener(_onWebViewReadyChanged);
      final url = widget.process.previewUrl!;
      _loadedUrl = url;
      await controller.initialize(url.toString());
      _appliedBrightness = widget.mode.previewBrightness;
      _lastReloadToken = widget.process.previewReloadToken;
      final projectPath = widget.process.session.projectPath;
      final staleProfile = projectPath != null &&
          _cefProfileProjectPath != null &&
          _cefProfileProjectPath != projectPath;
      if (staleProfile) {
        // The profile still holds the previous project's state for this same
        // origin. Clear it, and only then mark the profile as ours — a failed
        // clear lands in the catch below and stays due on the next attempt.
        await controller.clearBrowsingData(url.origin);
        _cefProfileProjectPath = projectPath;
        // The initial navigation above may already have been answered out of
        // the old state; reload() re-fetches past every cache and keeps the
        // overlay up until this project's own app is live.
        await reload();
      } else {
        if (projectPath != null) {
          _cefProfileProjectPath = projectPath;
        }
        _onWebViewReadyChanged();
      }
    } catch (e) {
      _error = e.toString();
      await _disposeController();
    } finally {
      _initializing = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _applyPreviewTheme(Brightness brightness) async {
    if (_appliedBrightness == brightness) return;
    final controller = _controller;
    if (controller == null || !controller.value) return;
    try {
      await controller.executeJavaScript(
        previewThemeApplyCall(isDark: brightness == Brightness.dark),
      );
      _appliedBrightness = brightness;
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _tearDownWebView() {
    _revealGeneration++;
    _error = null;
    _lastReloadToken = 0;
    _appliedBrightness = null;
    _loadedUrl = null;
    unawaited(_disposeController().then((_) {
      if (mounted) setState(() {});
    }));
  }

  void _onWebViewReadyChanged() {
    final controller = _controller;
    if (controller == null || !controller.value) return;
    unawaited(_revealWhenAppReady(controller));
  }

  Future<void> _revealWhenAppReady(WebViewController controller) async {
    final revealGeneration = ++_revealGeneration;
    await _waitForFlutterMain(
      controller,
      isCancelled: () =>
          !mounted ||
          _controller != controller ||
          revealGeneration != _revealGeneration,
    );
    if (!mounted || revealGeneration != _revealGeneration) return;
    widget.process.markPreviewLive();
    if (mounted) setState(() {});
  }

  /// Drops the caches that live inside the page, so the reload cannot be
  /// answered out of the previous build.
  ///
  /// Bounded and best-effort: the purge is asynchronous and there is no way to
  /// await it from here, so a page that never raises the flag costs a second
  /// and reloads anyway. Not reloading is the worse failure.
  Future<void> _purgePageCaches(WebViewController controller) async {
    const maxAttempts = 5;
    const delay = Duration(milliseconds: 200);
    try {
      await controller.executeJavaScript(previewCachePurgeScript);
    } catch (_) {
      return;
    }
    for (var i = 0; i < maxAttempts; i++) {
      try {
        final done = await controller.evaluateJavascript(
          previewCachesPurgedFlag,
        );
        if (done == true || done == 'true') return;
      } catch (_) {
        return;
      }
      await Future<void>.delayed(delay);
    }
  }

  /// Keeps the overlay up until Flutter web has actually started (or we time out).
  Future<void> _waitForFlutterMain(
    WebViewController controller, {
    required bool Function() isCancelled,
  }) async {
    // Bootstrap may wait ~2.5s for DWDS before calling `$dartRunMain`.
    const maxAttempts = 40;
    const delay = Duration(milliseconds: 200);
    for (var i = 0; i < maxAttempts; i++) {
      if (isCancelled()) return;
      try {
        final result = await controller.evaluateJavascript(
          'window.\$dartMainExecuted === true || '
          'document.querySelector("flt-glass-pane, flt-scene-host, flutter-view") != null',
        );
        if (result == true || result == 'true') return;
      } catch (_) {}
      await Future<void>.delayed(delay);
    }
  }

  Future<void> _disposeController() async {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    controller.removeListener(_onWebViewReadyChanged);
    try {
      await controller.dispose();
    } catch (_) {}
  }

  @override
  void dispose() {
    widget.process.removeListener(_onProcessChanged);
    widget.mode.removeListener(_onModeChanged);
    unawaited(_disposeController());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mode = widget.mode;
    final viewport = previewPhoneViewport(mode.viewMode.orientation);
    final registrationCode = widget.process.registrationCode;

    if (mode.compactWindow) {
      return _buildCompactWindow(
        viewport: viewport,
        registrationCode: registrationCode,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PreviewHeaderBar(
          previewBrightness: mode.previewBrightness,
          viewMode: mode.viewMode,
          minimized: mode.minimized,
          onPreviewThemeChanged: mode.setPreviewBrightness,
          onViewModeChanged: mode.setViewMode,
          onToggleMinimized: mode.toggleMinimized,
        ),
        Expanded(
          child: Stack(
            children: [
              PreviewHeroGradient(
                animating: widget.gradientAnimating,
                child: _buildBody(viewport: viewport),
              ),
              // Floats over the whole preview area — including the CEF surface
              // — rather than inside the phone frame.
              if (registrationCode != null)
                Positioned(
                  top: 32,
                  left: 12,
                  right: 12,
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: RegistrationCodeToast(
                      code: registrationCode,
                      onDismiss: widget.process.dismissRegistrationCode,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// The bare frame plus a floating control bar, on a transparent window.
  ///
  /// No header, no gradient: everything painted here shows on the user's
  /// desktop. The frame is the window — its edges move it, its corners resize
  /// it — so the handles ride on the frame's own aspect box, where they line
  /// up with the drawn bezel at every window size.
  Widget _buildCompactWindow({
    required Size viewport,
    String? registrationCode,
  }) {
    final mode = widget.mode;
    return Padding(
      padding: const EdgeInsets.all(kCompactFrameMargin),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _PhonePreviewViewport(
              viewport: viewport,
              padding: EdgeInsets.zero,
              overlay: Stack(
                children: [
                  _CompactWindowHandles(mode: mode),
                  if (registrationCode != null)
                    Positioned(
                      top: 32,
                      left: 12,
                      right: 12,
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: RegistrationCodeToast(
                          code: registrationCode,
                          onDismiss: widget.process.dismissRegistrationCode,
                        ),
                      ),
                    ),
                ],
              ),
              child: _buildSurfaceStack(viewport: viewport),
            ),
          ),
          const SizedBox(height: kCompactBarGap),
          CompactControlBar(
            status: widget.process.status,
            viewMode: mode.viewMode,
            previewBrightness: mode.previewBrightness,
            onViewModeChanged: mode.setViewMode,
            onPreviewThemeChanged: mode.setPreviewBrightness,
            onExpand: mode.expand,
          ),
        ],
      ),
    );
  }

  Widget _buildBody({required Size viewport}) {
    final framed = _buildSurfaceStack(viewport: viewport);

    if (widget.mode.viewMode.displayMode == PreviewDisplayMode.desktop) {
      return framed;
    }

    return _PhonePreviewViewport(
      viewport: viewport,
      child: framed,
    );
  }

  Widget _buildSurfaceStack({required Size viewport}) {
    final controller = _controller;
    final phase = widget.process.phase;
    final processError = widget.process.error;
    final overlayError = _error ?? processError;
    final cefReady = controller != null &&
        !_initializing &&
        controller.value;
    final cefLoading = _shouldLoad && !cefReady && overlayError == null;

    Widget surface;
    if (cefReady) {
      surface = ValueListenableBuilder<bool>(
        valueListenable: controller,
        builder: (context, ready, _) {
          if (!ready) {
            return const ColoredBox(color: Color(0xFF12122A));
          }
          final viewMode = widget.mode.viewMode;
          final phoneViewport =
              viewMode.displayMode == PreviewDisplayMode.phone
                  ? viewport
                  : null;
          return PreviewSurfaceSync(
            controller: controller,
            explicitSize: phoneViewport,
            child: controller.webviewWidget,
          );
        },
      );
    } else {
      surface = const ColoredBox(color: Color(0xFF12122A));
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // CEF composites with an alpha channel, so anything the page leaves
        // unpainted would show the shell through. Back it with the previewed
        // app's own light/dark, not App Studio's.
        ColoredBox(
          key: const ValueKey('preview-backdrop'),
          color: previewBackdropColor(widget.mode.previewBrightness),
        ),
        surface,
        PreviewStatusOverlay(
          phase: phase,
          errorMessage: overlayError,
          cefLoading: cefLoading,
        ),
      ],
    );
  }
}

/// Move/resize hit areas riding on the phone frame's bezel.
///
/// Edges move the window, corners resize it; both hand the drag to the native
/// side on the first pan event, which then tracks the mouse itself — Dart
/// deltas would be measured against a window that is moving under them.
class _CompactWindowHandles extends StatelessWidget {
  const _CompactWindowHandles({required this.mode});

  final PreviewModeController mode;

  /// Covers the 10px bezel with a little slop inward.
  static const _edgeThickness = 14.0;
  static const _cornerSize = 26.0;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: _cornerSize,
          right: _cornerSize,
          height: _edgeThickness,
          child: _moveHandle(),
        ),
        Positioned(
          bottom: 0,
          left: _cornerSize,
          right: _cornerSize,
          height: _edgeThickness,
          child: _moveHandle(),
        ),
        Positioned(
          left: 0,
          top: _cornerSize,
          bottom: _cornerSize,
          width: _edgeThickness,
          child: _moveHandle(),
        ),
        Positioned(
          right: 0,
          top: _cornerSize,
          bottom: _cornerSize,
          width: _edgeThickness,
          child: _moveHandle(),
        ),
        _corner(top: 0, left: 0, corner: CompactResizeCorner.topLeft),
        _corner(top: 0, right: 0, corner: CompactResizeCorner.topRight),
        _corner(bottom: 0, left: 0, corner: CompactResizeCorner.bottomLeft),
        _corner(bottom: 0, right: 0, corner: CompactResizeCorner.bottomRight),
      ],
    );
  }

  Widget _moveHandle() {
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => mode.startWindowDrag(),
      ),
    );
  }

  Widget _corner({
    double? top,
    double? bottom,
    double? left,
    double? right,
    required CompactResizeCorner corner,
  }) {
    return Positioned(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      width: _cornerSize,
      height: _cornerSize,
      // The diagonal resize cursor comes from AppKit via the controller — the
      // macOS engine maps no diagonal SystemMouseCursors (they fall back to
      // the arrow). `basic` here keeps the framework from re-asserting a grab
      // cursor while the pointer sits on the corner.
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        onEnter: (_) => mode.showResizeCursor(corner),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (_) => mode.startWindowResize(corner),
        ),
      ),
    );
  }
}

class _PhonePreviewViewport extends StatelessWidget {
  const _PhonePreviewViewport({
    required this.viewport,
    required this.child,
    this.padding = const EdgeInsets.all(previewPhonePreviewPadding),
    this.overlay,
  });

  final Size viewport;
  final Widget child;
  final EdgeInsets padding;

  /// Drawn over the frame, in the aspect box's own coordinates — which match
  /// the frame exactly, since the [FittedBox] fills the box edge to edge.
  final Widget? overlay;

  @override
  Widget build(BuildContext context) {
    final frameSize = previewPhoneFrameSize(
      viewport.width > viewport.height
          ? PreviewOrientation.landscape
          : PreviewOrientation.portrait,
    );

    Widget content = FittedBox(
      fit: BoxFit.contain,
      child: SizedBox(
        width: frameSize.width,
        height: frameSize.height,
        child: _PhoneDeviceFrame(
          viewport: viewport,
          child: SizedBox(
            width: viewport.width,
            height: viewport.height,
            child: child,
          ),
        ),
      ),
    );
    if (overlay != null) {
      content = Stack(
        fit: StackFit.expand,
        children: [content, overlay!],
      );
    }

    return Padding(
      padding: padding,
      child: Center(
        child: AspectRatio(
          aspectRatio: frameSize.width / frameSize.height,
          child: content,
        ),
      ),
    );
  }
}

class _PhoneDeviceFrame extends StatelessWidget {
  const _PhoneDeviceFrame({
    required this.viewport,
    required this.child,
  });

  final Size viewport;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDarkShell = ShadTheme.of(context).brightness == Brightness.dark;
    final bezelColor =
        isDarkShell ? const Color(0xFF2A2A2E) : const Color(0xFF1C1C1E);

    return Container(
      padding: const EdgeInsets.all(previewPhoneBezel),
      decoration: BoxDecoration(
        color: bezelColor,
        borderRadius: BorderRadius.circular(previewPhoneOuterCornerRadius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDarkShell ? 0.55 : 0.28),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(previewPhoneCornerRadius),
        child: child,
      ),
    );
  }
}
