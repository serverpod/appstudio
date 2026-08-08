import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import 'preview_phase.dart';

/// Full-bleed status layer drawn over the phone (or desktop) preview surface.
class PreviewStatusOverlay extends StatelessWidget {
  const PreviewStatusOverlay({
    super.key,
    required this.phase,
    this.errorMessage,
    this.cefLoading = false,
  });

  final PreviewPhase phase;
  final String? errorMessage;

  /// True while the webview is initializing even after the port is ready.
  final bool cefLoading;

  static const _footerSlotHeight = 20.0;

  bool get _isError => errorMessage != null || phase.isError;

  bool get _visible {
    if (_isError) return true;
    if (cefLoading &&
        (phase == PreviewPhase.loadingApp ||
            phase == PreviewPhase.connecting ||
            phase == PreviewPhase.ready)) {
      return true;
    }
    return phase.showsLoadingOverlay;
  }

  String get _title {
    if (_isError) return 'Byte took a tumble';
    if (cefLoading &&
        (phase == PreviewPhase.ready || phase == PreviewPhase.loadingApp)) {
      return PreviewPhase.loadingApp.overlayMessage;
    }
    if (cefLoading && phase == PreviewPhase.connecting) {
      return PreviewPhase.connecting.overlayMessage;
    }
    return phase.overlayMessage;
  }

  String? get _detail {
    if (!_isError) return null;
    final detail = errorMessage?.trim();
    if (detail == null || detail.isEmpty) return null;
    return detail;
  }

  String get _artAsset {
    if (_isError) return 'assets/byte-crash.webp';
    if (phase.isStopped) return 'assets/nova-bored.webp';
    return 'assets/nova-running.webp';
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();

    final textTheme = ShadTheme.of(context).textTheme;

    return Positioned.fill(
      child: ColoredBox(
        color: const Color(0xFF12122A),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final artSize = (constraints.biggest.shortestSide * 0.5)
                .clamp(96.0, 280.0);
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: artSize,
                    height: artSize,
                    child: Image.asset(
                      _artAsset,
                      // Match rendered height across Nova assets so the title
                      // doesn't jump when switching running ↔ bored.
                      fit: BoxFit.fitHeight,
                      alignment: Alignment.center,
                      filterQuality: FilterQuality.medium,
                      gaplessPlayback: true,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    _title,
                    textAlign: TextAlign.center,
                    style: textTheme.small.copyWith(
                      color: Colors.white.withValues(alpha: 0.94),
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                  if (_detail != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _detail!,
                      textAlign: TextAlign.center,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.small.copyWith(
                        color: Colors.white.withValues(alpha: 0.62),
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    height: _footerSlotHeight,
                    width: artSize * 0.55,
                    child: _buildFooter(textTheme),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildFooter(ShadTextTheme textTheme) {
    if (_isError) return const SizedBox.shrink();
    if (phase.isStopped) {
      return Center(
        child: Text(
          'System stopped',
          textAlign: TextAlign.center,
          style: textTheme.small.copyWith(
            color: Colors.white.withValues(alpha: 0.62),
            fontSize: 12,
            height: 1.0,
          ),
        ),
      );
    }
    return const Center(
      child: ShadProgress(value: null, minHeight: 3),
    );
  }
}
