import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:webview_cef/webview_cef.dart';

import '../preview/preview_bootstrap.dart';
import '../preview/preview_device.dart';
import '../preview/preview_surface_sync.dart';
import '../preview/preview_theme.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/icon_segmented_control.dart';
import '../widgets/text_segmented_control.dart';

enum _PreviewHeaderLabel { preview }

class PreviewPane extends StatefulWidget {
  const PreviewPane({
    super.key,
    required this.previewUrl,
    required this.shouldLoad,
    this.reloadToken = 0,
  });

  final Uri previewUrl;
  final bool shouldLoad;
  final int reloadToken;

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

  Future<void> reload() async {
    if (!widget.shouldLoad) return;
    final controller = _controller;
    if (controller == null || !controller.value) {
      await _ensureWebView();
      return;
    }
    try {
      await controller.loadUrl(widget.previewUrl.toString());
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void didUpdateWidget(covariant PreviewPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.shouldLoad && oldWidget.shouldLoad) {
      _tearDownWebView();
      return;
    }
    if (widget.shouldLoad && !oldWidget.shouldLoad) {
      _ensureWebView();
      return;
    }
    if (widget.shouldLoad &&
        widget.reloadToken != _lastReloadToken &&
        widget.reloadToken > 0) {
      _lastReloadToken = widget.reloadToken;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) reload();
      });
    }
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
    if (!widget.shouldLoad || _initializing) return;
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
        loading: const _PreviewLoadingIndicator(),
        injectUserScripts: scripts,
      );
      _controller = controller;
      await controller.initialize(widget.previewUrl.toString());
      _appliedBrightness = _previewBrightness;
      _lastReloadToken = widget.reloadToken;
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
    _error = null;
    _lastReloadToken = 0;
    _appliedBrightness = null;
    unawaited(_disposeController().then((_) {
      if (mounted) setState(() {});
    }));
  }

  Future<void> _disposeController() async {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    try {
      await controller.dispose();
    } catch (_) {}
  }

  @override
  void dispose() {
    unawaited(_disposeController());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final viewport = previewPhoneViewport(_viewMode.orientation);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PreviewHeaderBar(
          previewBrightness: _previewBrightness,
          viewMode: _viewMode,
          onPreviewThemeChanged: _setPreviewTheme,
          onViewModeChanged: _setViewMode,
        ),
        Expanded(
          child: ColoredBox(
            color: ShadTheme.of(context).colorScheme.background,
            child: _buildBody(
              controller,
              viewport: viewport,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBody(
    WebViewController? controller, {
    required Size viewport,
  }) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final isDark = theme.brightness == Brightness.dark;

    if (_error != null) {
      return Center(
        child: Text(
          'Preview error: $_error',
          style: textTheme.small.copyWith(
            color: isDark ? AppColors.errorTextDark : AppColors.errorText,
          ),
        ),
      );
    }

    if (!widget.shouldLoad) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.globe, size: 28, color: scheme.mutedForeground),
            const SizedBox(height: 12),
            Text(
              'Preview will appear when the app is ready',
              style: textTheme.muted,
            ),
          ],
        ),
      );
    }

    if (controller == null || _initializing || !controller.value) {
      return const Center(child: _PreviewLoadingIndicator());
    }

    return ValueListenableBuilder<bool>(
      valueListenable: controller,
      builder: (context, ready, _) {
        if (!ready) return controller.loadingWidget;
        final phoneViewport = _viewMode.displayMode == PreviewDisplayMode.phone
            ? viewport
            : null;
        final webView = PreviewSurfaceSync(
          controller: controller,
          explicitSize: phoneViewport,
          child: controller.webviewWidget,
        );
        if (_viewMode.displayMode == PreviewDisplayMode.desktop) {
          return webView;
        }
        return _PhonePreviewViewport(
          viewport: viewport,
          child: webView,
        );
      },
    );
  }
}

class _PreviewLoadingIndicator extends StatelessWidget {
  const _PreviewLoadingIndicator();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 120,
          child: ShadProgress(value: null, minHeight: 4),
        ),
        const SizedBox(height: 12),
        Text(
          'Loading preview…',
          style: ShadTheme.of(context).textTheme.muted,
        ),
      ],
    );
  }
}

class _PreviewHeaderBar extends StatelessWidget {
  const _PreviewHeaderBar({
    required this.previewBrightness,
    required this.viewMode,
    required this.onPreviewThemeChanged,
    required this.onViewModeChanged,
  });

  final Brightness previewBrightness;
  final PreviewViewMode viewMode;
  final ValueChanged<Brightness> onPreviewThemeChanged;
  final ValueChanged<PreviewViewMode> onViewModeChanged;

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
    final scheme = ShadTheme.of(context).colorScheme;
    final frameSize = previewPhoneFrameSize(
      viewport.width > viewport.height
          ? PreviewOrientation.landscape
          : PreviewOrientation.portrait,
    );

    return ColoredBox(
      color: scheme.background,
      child: Padding(
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
    final bezelColor = isDarkShell ? const Color(0xFF2A2A2E) : const Color(0xFF1C1C1E);

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
