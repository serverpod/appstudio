import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:webview_cef/webview_cef.dart';

import '../preview/preview_bootstrap.dart';
import '../preview/preview_device.dart';
import '../preview/preview_hero_gradient.dart';
import '../preview/preview_status_overlay.dart';
import '../preview/registration_code_toast.dart';
import '../preview/preview_surface_sync.dart';
import '../preview/preview_theme.dart';
import '../process/serverpod_process.dart';
import '../theme/app_theme.dart';
import '../widgets/icon_segmented_control.dart';
import '../widgets/text_segmented_control.dart';

enum _PreviewHeaderLabel { preview }

class PreviewPane extends StatefulWidget {
  const PreviewPane({
    super.key,
    required this.previewUrl,
    required this.process,
    this.gradientAnimating = false,
  });

  final Uri previewUrl;
  final ServerpodProcessController process;
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

  Brightness _previewBrightness = Brightness.light;
  PreviewViewMode _viewMode = PreviewViewMode.phonePortrait;
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
      // Hard reload: a plain navigation re-serves the cached main.dart.js, so
      // a rebuilt app would look unchanged.
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
      await _applyPreviewTheme(_previewBrightness);
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
  }

  void _onProcessChanged() {
    if (!mounted) return;

    final shouldLoad = widget.process.previewReady;
    final reloadToken = widget.process.previewReloadToken;

    if (!shouldLoad && _controller != null) {
      _tearDownWebView();
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

  void _setPreviewTheme(Brightness brightness) {
    if (_previewBrightness == brightness) return;
    setState(() => _previewBrightness = brightness);
    unawaited(_applyPreviewTheme(brightness));
  }

  void _setViewMode(PreviewViewMode mode) {
    if (_viewMode == mode) return;
    setState(() => _viewMode = mode);
    _requestSurfaceSync();
  }

  void _requestSurfaceSync() {
    unawaited(_burstSyncPreviewSurface());
  }

  Future<void> _burstSyncPreviewSurface() async {
    final controller = _controller;
    if (controller == null || !controller.value || !mounted) return;

    _surfaceSyncGeneration++;
    final generation = _surfaceSyncGeneration;

    final phoneViewport = _viewMode.displayMode == PreviewDisplayMode.phone
        ? previewPhoneViewport(_viewMode.orientation)
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

      final isDark = _previewBrightness == Brightness.dark;
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
      await controller.initialize(widget.previewUrl.toString());
      _appliedBrightness = _previewBrightness;
      _lastReloadToken = widget.process.previewReloadToken;
      _onWebViewReadyChanged();
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
    unawaited(_disposeController().then((_) {
      if (mounted) setState(() {});
    }));
  }

  void _onWebViewReadyChanged() {
    final controller = _controller;
    if (controller == null || !controller.value) return;
    if (!widget.process.hasAttachedFlutter) {
      if (mounted) setState(() {});
      return;
    }
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
    unawaited(_disposeController());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final viewport = previewPhoneViewport(_viewMode.orientation);
    final registrationCode = widget.process.registrationCode;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PreviewHeaderBar(
          previewBrightness: _previewBrightness,
          viewMode: _viewMode,
          onPreviewThemeChanged: _setPreviewTheme,
          onViewModeChanged: _setViewMode,
          onReload: reload,
          canReload: widget.process.previewReady,
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

  Widget _buildBody({required Size viewport}) {
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
          final phoneViewport =
              _viewMode.displayMode == PreviewDisplayMode.phone
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

    final framed = Stack(
      fit: StackFit.expand,
      children: [
        // CEF composites with an alpha channel, so anything the page leaves
        // unpainted would show the shell through. Back it with the previewed
        // app's own light/dark, not App Studio's.
        ColoredBox(
          key: const ValueKey('preview-backdrop'),
          color: previewBackdropColor(_previewBrightness),
        ),
        surface,
        PreviewStatusOverlay(
          phase: phase,
          errorMessage: overlayError,
          cefLoading: cefLoading,
        ),
      ],
    );

    if (_viewMode.displayMode == PreviewDisplayMode.desktop) {
      return framed;
    }

    return _PhonePreviewViewport(
      viewport: viewport,
      child: framed,
    );
  }
}

class _PreviewHeaderBar extends StatelessWidget {
  const _PreviewHeaderBar({
    required this.previewBrightness,
    required this.viewMode,
    required this.onPreviewThemeChanged,
    required this.onViewModeChanged,
    required this.onReload,
    required this.canReload,
  });

  final Brightness previewBrightness;
  final PreviewViewMode viewMode;
  final ValueChanged<Brightness> onPreviewThemeChanged;
  final ValueChanged<PreviewViewMode> onViewModeChanged;
  final VoidCallback onReload;
  final bool canReload;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      height: kPaneHeaderHeight,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: scheme.muted,
        border: Border(bottom: paneBorderSide(scheme.border)),
      ),
      child: Row(
        children: [
          TextSegmentedControl<_PreviewHeaderLabel>(
            value: _PreviewHeaderLabel.preview,
            onChanged: (_) {},
            interactive: false,
            onMutedSurface: true,
            segments: const [
              TextSegment(
                value: _PreviewHeaderLabel.preview,
                label: 'Preview',
              ),
            ],
          ),
          const Spacer(),
          IconSegmentedControl<PreviewViewMode>(
            value: viewMode,
            onChanged: onViewModeChanged,
            onMutedSurface: true,
            segments: const [
              IconSegment(
                value: PreviewViewMode.phonePortrait,
                tooltip: 'Phone preview',
                icon: LucideIcons.smartphone,
              ),
              IconSegment(
                value: PreviewViewMode.phoneLandscape,
                tooltip: 'Phone preview (landscape)',
                icon: LucideIcons.smartphone,
                iconRotation: 1.5707963267948966,
              ),
              IconSegment(
                value: PreviewViewMode.desktop,
                tooltip: 'Desktop preview',
                icon: LucideIcons.monitor,
              ),
            ],
          ),
          const SizedBox(width: 8),
          IconSegmentedControl<Brightness>(
            value: previewBrightness,
            onChanged: onPreviewThemeChanged,
            onMutedSurface: true,
            segments: const [
              IconSegment(
                value: Brightness.light,
                tooltip: 'App theme: Light',
                icon: LucideIcons.sun,
              ),
              IconSegment(
                value: Brightness.dark,
                tooltip: 'App theme: Dark',
                icon: LucideIcons.moon,
              ),
            ],
          ),
          const SizedBox(width: 8),
          SegmentedIconButton(
            icon: LucideIcons.refreshCw,
            tooltip: 'Reload preview',
            onMutedSurface: true,
            onPressed: canReload ? onReload : null,
          ),
        ],
      ),
    );
  }
}

class _PhonePreviewViewport extends StatelessWidget {
  const _PhonePreviewViewport({
    required this.viewport,
    required this.child,
  });

  final Size viewport;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final frameSize = previewPhoneFrameSize(
      viewport.width > viewport.height
          ? PreviewOrientation.landscape
          : PreviewOrientation.portrait,
    );

    return Padding(
      padding: const EdgeInsets.all(previewPhonePreviewPadding),
      child: Center(
        child: AspectRatio(
          aspectRatio: frameSize.width / frameSize.height,
          child: FittedBox(
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
          ),
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
