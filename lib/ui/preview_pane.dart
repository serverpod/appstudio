import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:webview_cef/webview_cef.dart';

import '../preview/preview_bootstrap.dart';
import '../preview/preview_device.dart';
import '../preview/preview_surface_sync.dart';
import '../preview/preview_theme.dart';
import '../theme/app_theme.dart';

class PreviewPane extends StatefulWidget {
  const PreviewPane({
    super.key,
    required this.previewUrl,
    required this.shouldLoad,
    this.reloadToken = 0,
  });

  final Uri previewUrl;
  final bool shouldLoad;
  /// When this value increases, reload the current preview URL.
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
  PreviewDisplayMode _displayMode = PreviewDisplayMode.desktop;
  PreviewOrientation _orientation = PreviewOrientation.portrait;
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

  void _togglePreviewTheme() {
    setState(() {
      _previewBrightness = _previewBrightness == Brightness.light
          ? Brightness.dark
          : Brightness.light;
    });
    unawaited(_applyPreviewTheme(_previewBrightness));
  }

  void _setDisplayMode(PreviewDisplayMode mode) {
    if (_displayMode == mode) return;
    setState(() => _displayMode = mode);
    _requestSurfaceSync();
  }

  void _toggleOrientation() {
    if (_displayMode != PreviewDisplayMode.phone) return;
    setState(() {
      _orientation = _orientation == PreviewOrientation.portrait
          ? PreviewOrientation.landscape
          : PreviewOrientation.portrait;
    });
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

    final phoneViewport = _displayMode == PreviewDisplayMode.phone
        ? previewPhoneViewport(_orientation)
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
        loading: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
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
    final colors = Theme.of(context).extension<AppColors>()!;
    final controller = _controller;
    final viewport = previewPhoneViewport(_orientation);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PreviewHeaderBar(
          colors: colors,
          previewUrl: widget.previewUrl,
          previewBrightness: _previewBrightness,
          displayMode: _displayMode,
          orientation: _orientation,
          onToggleTheme: _togglePreviewTheme,
          onDisplayModeChanged: _setDisplayMode,
          onToggleOrientation: _toggleOrientation,
        ),
        Expanded(
          child: _buildBody(
            controller,
            colors,
            viewport: viewport,
          ),
        ),
      ],
    );
  }

  Widget _buildBody(
    WebViewController? controller,
    AppColors colors, {
    required Size viewport,
  }) {
    if (_error != null) {
      return Center(
        child: Text(
          'Preview error: $_error',
          style: GoogleFonts.ibmPlexSans(color: colors.statusDanger),
        ),
      );
    }

    if (!widget.shouldLoad) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.globe, size: 28, color: colors.emptyStateMuted),
            const SizedBox(height: 12),
            Text(
              'Preview will appear when the app is ready',
              style: GoogleFonts.ibmPlexSans(
                fontSize: 13,
                color: colors.emptyStateMuted,
              ),
            ),
          ],
        ),
      );
    }

    if (controller == null || _initializing || !controller.value) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(height: 12),
            Text(
              'Loading preview…',
              style: GoogleFonts.ibmPlexSans(
                fontSize: 13,
                color: colors.emptyStateMuted,
              ),
            ),
          ],
        ),
      );
    }

    return ValueListenableBuilder<bool>(
      valueListenable: controller,
      builder: (context, ready, _) {
        if (!ready) return controller.loadingWidget;
        final phoneViewport = _displayMode == PreviewDisplayMode.phone
            ? viewport
            : null;
        final webView = PreviewSurfaceSync(
          controller: controller,
          explicitSize: phoneViewport,
          child: controller.webviewWidget,
        );
        if (_displayMode == PreviewDisplayMode.desktop) {
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

class _PreviewHeaderBar extends StatelessWidget {
  const _PreviewHeaderBar({
    required this.colors,
    required this.previewUrl,
    required this.previewBrightness,
    required this.displayMode,
    required this.orientation,
    required this.onToggleTheme,
    required this.onDisplayModeChanged,
    required this.onToggleOrientation,
  });

  final AppColors colors;
  final Uri previewUrl;
  final Brightness previewBrightness;
  final PreviewDisplayMode displayMode;
  final PreviewOrientation orientation;
  final VoidCallback onToggleTheme;
  final ValueChanged<PreviewDisplayMode> onDisplayModeChanged;
  final VoidCallback onToggleOrientation;

  @override
  Widget build(BuildContext context) {
    final viewport = previewPhoneViewport(orientation);
    final sizeLabel = displayMode == PreviewDisplayMode.phone
        ? '${viewport.width.toInt()}×${viewport.height.toInt()}'
        : null;

    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: colors.paneHeaderBackground,
        border: Border(bottom: BorderSide(color: colors.divider, width: 1)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.globe, size: 14, color: colors.statusIdle),
          const SizedBox(width: 8),
          Text(
            'Preview',
            style: GoogleFonts.ibmPlexSans(
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (sizeLabel != null) ...[
            const SizedBox(width: 8),
            Text(
              sizeLabel,
              style: GoogleFonts.ibmPlexMono(
                fontSize: 10,
                color: colors.emptyStateMuted,
              ),
            ),
          ],
          const Spacer(),
          _PreviewIconAction(
            icon: previewBrightness == Brightness.dark
                ? LucideIcons.moon
                : LucideIcons.sun,
            tooltip: previewBrightness == Brightness.dark
                ? 'App theme: Dark'
                : 'App theme: Light',
            onPressed: onToggleTheme,
          ),
          _PreviewToggleAction(
            icon: LucideIcons.monitor,
            tooltip: 'Desktop preview',
            selected: displayMode == PreviewDisplayMode.desktop,
            onPressed: () => onDisplayModeChanged(PreviewDisplayMode.desktop),
          ),
          _PreviewToggleAction(
            icon: LucideIcons.smartphone,
            tooltip: 'Phone preview',
            selected: displayMode == PreviewDisplayMode.phone,
            onPressed: () => onDisplayModeChanged(PreviewDisplayMode.phone),
          ),
          _PreviewIconAction(
            icon: LucideIcons.rotateCw,
            tooltip: orientation == PreviewOrientation.portrait
                ? 'Switch to landscape'
                : 'Switch to portrait',
            onPressed:
                displayMode == PreviewDisplayMode.phone ? onToggleOrientation : null,
          ),
          const SizedBox(width: 4),
          Tooltip(
            message: previewUrl.toString(),
            child: Padding(
              padding: const EdgeInsets.only(left: 4, right: 4),
              child: Icon(
                LucideIcons.link,
                size: 13,
                color: colors.emptyStateMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewIconAction extends StatelessWidget {
  const _PreviewIconAction({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, size: 16),
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      ),
    );
  }
}

class _PreviewToggleAction extends StatelessWidget {
  const _PreviewToggleAction({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    return Tooltip(
      message: tooltip,
      child: IconButton(
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: selected ? colors.badgeBackground : null,
        ),
        icon: Icon(
          icon,
          size: 16,
          color: selected ? colors.badgeForeground : colors.emptyStateMuted,
        ),
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      ),
    );
  }
}

/// Scales a fixed-size phone viewport to fit the panel; CEF keeps [viewport] px.
class _PhonePreviewViewport extends StatelessWidget {
  const _PhonePreviewViewport({
    required this.viewport,
    required this.child,
  });

  final Size viewport;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<AppColors>()!;
    final frameSize = previewPhoneFrameSize(
      viewport.width > viewport.height
          ? PreviewOrientation.landscape
          : PreviewOrientation.portrait,
    );

    return ColoredBox(
      color: colors.toolbarBackground,
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
    final isDarkShell = Theme.of(context).brightness == Brightness.dark;
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
