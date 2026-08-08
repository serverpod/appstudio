import 'package:flutter/material.dart';

const _kBannerHeight = 56.0;
const _kLogoAsset = 'assets/logo-horizontal.webp';
const _kBackgroundAsset = 'assets/background.webp';

/// Natural pixel size of [assets/background.webp].
const _kBackgroundAspectRatio = 2394 / 1247;

/// The branded chrome every pre-project screen shares: the logo banner above
/// the gradient, with [child] laid over the gradient.
///
/// Shared rather than duplicated because first-run setup and the start page are
/// two states of the same moment — the app open with no project — and giving
/// them different backdrops made moving between them look like a different app.
///
/// Free of `dart:io` on purpose: [child] is what varies, so this stays
/// previewable even though `StartPage` itself is not.
class LandingScaffold extends StatelessWidget {
  const LandingScaffold({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _LandingBanner(),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [const _LandingBackground(), child],
          ),
        ),
      ],
    );
  }
}

class _LandingBanner extends StatelessWidget {
  const _LandingBanner();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      // Brand chrome, identical in both themes, so this one is not a token.
      color: Colors.black,
      child: SizedBox(
        height: _kBannerHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Image.asset(
              _kLogoAsset,
              height: 28,
              fit: BoxFit.contain,
              alignment: Alignment.centerLeft,
              filterQuality: FilterQuality.medium,
            ),
          ),
        ),
      ),
    );
  }
}

class _LandingBackground extends StatelessWidget {
  const _LandingBackground();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = constraints.maxHeight;
        final width = constraints.maxWidth;
        final naturalWidth = height * _kBackgroundAspectRatio;

        if (naturalWidth < width) {
          return Image.asset(
            _kBackgroundAsset,
            width: width,
            height: height,
            fit: BoxFit.fill,
            alignment: Alignment.center,
            filterQuality: FilterQuality.medium,
          );
        }

        return ClipRect(
          child: Align(
            alignment: Alignment.center,
            child: Image.asset(
              _kBackgroundAsset,
              height: height,
              fit: BoxFit.fitHeight,
              filterQuality: FilterQuality.medium,
            ),
          ),
        );
      },
    );
  }
}
