import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:webview_cef/webview_cef.dart';

import '../theme/app_theme.dart';

class PreviewPane extends StatefulWidget {
  const PreviewPane({
    super.key,
    required this.previewUrl,
    required this.shouldLoad,
  });

  final Uri previewUrl;
  final bool shouldLoad;

  @override
  State<PreviewPane> createState() => PreviewPaneState();
}

class PreviewPaneState extends State<PreviewPane> {
  WebViewController? _controller;
  bool _initializing = false;
  bool _initialized = false;
  String? _error;

  Future<void> reload() async {
    if (!widget.shouldLoad) return;
    final controller = _controller;
    if (controller == null) {
      await _ensureWebView();
      return;
    }
    await controller.loadUrl(widget.previewUrl.toString());
  }

  @override
  void didUpdateWidget(covariant PreviewPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shouldLoad && !oldWidget.shouldLoad) {
      _ensureWebView();
    }
  }

  Future<void> _ensureWebView() async {
    if (!widget.shouldLoad || _initializing) return;
    _initializing = true;
    _error = null;
    if (mounted) setState(() {});

    try {
      if (!_initialized) {
        await WebviewManager().initialize(
          userAgent: 'AppStudio/1.0 (Chromium CEF)',
        );
        _initialized = true;
      }

      _controller ??= WebviewManager().createWebView(
        loading: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        injectUserScripts: InjectUserScripts(),
      );

      await _controller!.initialize(widget.previewUrl.toString());
    } catch (e) {
      _error = e.toString();
    } finally {
      _initializing = false;
      if (mounted) setState(() {});
    }
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

    if (controller == null || _initializing) {
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
