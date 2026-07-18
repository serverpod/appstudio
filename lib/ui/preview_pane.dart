import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:webview_cef/webview_cef.dart';

import '../preview/preview_bootstrap.dart';
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

      // webview_cef binds each controller's temp index once; never re-initialize.
      await _disposeController();

      final scripts = InjectUserScripts()
        ..add(
          UserScript(previewBootstrapScript, ScriptInjectTime.LOAD_START),
        );

      final controller = WebviewManager().createWebView(
        loading: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        injectUserScripts: scripts,
      );
      _controller = controller;
      await controller.initialize(widget.previewUrl.toString());
      _lastReloadToken = widget.reloadToken;
    } catch (e) {
      _error = e.toString();
      await _disposeController();
    } finally {
      _initializing = false;
      if (mounted) setState(() {});
    }
  }

  void _tearDownWebView() {
    _error = null;
    _lastReloadToken = 0;
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: colors.paneHeaderBackground,
            border: Border(
              bottom: BorderSide(color: colors.divider, width: 1),
            ),
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
              const Spacer(),
              Text(
                widget.previewUrl.toString(),
                style: GoogleFonts.ibmPlexMono(
                  fontSize: 11,
                  color: colors.emptyStateMuted,
                ),
              ),
            ],
          ),
        ),
        Expanded(child: _buildBody(controller, colors)),
      ],
    );
  }

  Widget _buildBody(WebViewController? controller, AppColors colors) {
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
        return controller.webviewWidget;
      },
    );
  }
}
