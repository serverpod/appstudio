import 'package:flutter/material.dart';
import 'package:mesh_gradient/mesh_gradient.dart';

import 'preview_hero_palette.dart';

/// Hero-artwork mesh backdrop for the preview pane (GPU shader via mesh_gradient).
class PreviewHeroGradient extends StatefulWidget {
  const PreviewHeroGradient({
    super.key,
    required this.animating,
    required this.child,
  });

  final bool animating;
  final Widget child;

  @override
  State<PreviewHeroGradient> createState() => _PreviewHeroGradientState();
}

class _PreviewHeroGradientState extends State<PreviewHeroGradient> {
  late final AnimatedMeshGradientController _controller;

  static final _options = AnimatedMeshGradientOptions(
    speed: 1.2,
    frequency: 3.5,
    amplitude: 28,
    grain: 0.06,
  );

  @override
  void initState() {
    super.initState();
    _controller = AnimatedMeshGradientController();
    if (widget.animating) {
      _controller.start();
    }
  }

  @override
  void didUpdateWidget(covariant PreviewHeroGradient oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animating == oldWidget.animating) return;
    if (widget.animating) {
      _controller.start();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedMeshGradient(
      controller: _controller,
      colors: PreviewHeroPalette.meshColors,
      options: _options,
      child: widget.child,
    );
  }
}
