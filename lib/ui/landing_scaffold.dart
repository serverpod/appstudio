import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../theme/app_theme.dart';

const _kBannerHeight = 56.0;
const _kLogoAsset = 'assets/logo-horizontal.webp';

/// The branded chrome every pre-project screen shares: the logo banner above
/// the gradient, with [child] laid over the gradient.
///
/// Shared rather than duplicated because first-run setup and the start page are
/// two states of the same moment — the app open with no project — and giving
/// them different backdrops made moving between them look like a different app.
///
/// [child] is given [buildLandingTheme] rather than the app's, so these screens
/// look the same in light mode as in dark — the backdrop is one fixed image
/// either way.
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
            children: [
              const _LandingBackground(),
              ShadTheme(data: buildLandingTheme(), child: child),
            ],
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

/// The brand backdrop: black at the banner, deepening through navy and indigo
/// into orchid at the floor.
///
/// Drawn rather than loaded. It replaced a 19 KB WebP that had to be decoded
/// and rescaled on every resize, and which the layout above had to letterbox by
/// hand to keep its aspect ratio — a gradient simply fills whatever it is given.
/// It is also darker at the bottom than the photograph was, which is what lets
/// the glass on top of it be white rather than black.
///
/// The nine colours are *measured*, not matched by eye: each is the design
/// reference's own pixel at that fraction of its height. Sampling on an even
/// eighth is what lets the `stops` list be omitted, and it tracks the reference
/// to within 3/255 on every channel — an earlier hand-picked set drifted by
/// nearly 40 in the last quarter, which is where the purple lives and where the
/// eye actually notices.
class _LandingBackground extends StatelessWidget {
  const _LandingBackground();

  static const _gradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFF000000),
      Color(0xFF000006),
      Color(0xFF020419),
      Color(0xFF090C37),
      Color(0xFF191A52),
      Color(0xFF31286D),
      Color(0xFF4E3785),
      Color(0xFF75469D),
      Color(0xFFA157B7),
    ],
  );

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(decoration: BoxDecoration(gradient: _gradient));
  }
}
