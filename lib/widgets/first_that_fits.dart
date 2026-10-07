import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Shows the first of [children] whose natural width fits the width it is
/// given, and the last one when none does.
///
/// For a row of controls with a compact fallback: the full version is used for
/// exactly as long as it fits, measured, rather than below a guessed
/// breakpoint that is wrong for every set of labels but one. Each child is
/// laid out at its natural width — unbounded — and compared; only the chosen
/// one is painted, hit-tested and visible to accessibility. The rest are still
/// built (their state survives a switch) but not shown.
class FirstThatFits extends MultiChildRenderObjectWidget {
  const FirstThatFits({super.key, required super.children});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderFirstThatFits();

  @override
  MultiChildRenderObjectElement createElement() =>
      _FirstThatFitsElement(this);
}

/// Reports only the shown child as on stage — what `find` and the inspector
/// walk — the way `Offstage` hides its child from them.
class _FirstThatFitsElement extends MultiChildRenderObjectElement {
  _FirstThatFitsElement(super.widget);

  @override
  void debugVisitOnstageChildren(ElementVisitor visitor) {
    final chosen = (renderObject as _RenderFirstThatFits)._chosen;
    for (final child in children) {
      if (child.renderObject == chosen) visitor(child);
    }
  }
}

class _FirstThatFitsParentData extends ContainerBoxParentData<RenderBox> {}

class _RenderFirstThatFits extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _FirstThatFitsParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _FirstThatFitsParentData> {
  RenderBox? _chosen;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _FirstThatFitsParentData) {
      child.parentData = _FirstThatFitsParentData();
    }
  }

  /// [constraints] with the width left open, so a child reports its natural
  /// width rather than squeezing into what it was offered.
  BoxConstraints _natural(BoxConstraints constraints) => BoxConstraints(
        minHeight: constraints.minHeight,
        maxHeight: constraints.maxHeight,
      );

  RenderBox? _pick(
    BoxConstraints constraints,
    Size Function(RenderBox child, BoxConstraints constraints) measure,
  ) {
    var child = firstChild;
    while (child != null) {
      final next = childAfter(child);
      if (next == null) return child;
      if (measure(child, _natural(constraints)).width <= constraints.maxWidth) {
        return child;
      }
      child = next;
    }
    return null;
  }

  @override
  void performLayout() {
    _chosen = _pick(constraints, (child, natural) {
      child.layout(natural, parentUsesSize: true);
      return child.size;
    });
    final chosen = _chosen;
    if (chosen == null) {
      size = constraints.smallest;
      return;
    }
    // The last resort may not fit either; it gets the width there is.
    chosen.layout(constraints.loosen(), parentUsesSize: true);
    size = constraints.constrain(chosen.size);
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final chosen = _pick(
      constraints,
      (child, natural) => child.getDryLayout(natural),
    );
    if (chosen == null) return constraints.smallest;
    return constraints.constrain(chosen.getDryLayout(constraints.loosen()));
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      lastChild?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      firstChild?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  double computeMinIntrinsicHeight(double width) =>
      firstChild?.getMinIntrinsicHeight(width) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      firstChild?.getMaxIntrinsicHeight(width) ?? 0;

  @override
  void paint(PaintingContext context, Offset offset) {
    final chosen = _chosen;
    if (chosen != null) context.paintChild(chosen, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final chosen = _chosen;
    if (chosen == null) return false;
    return result.addWithPaintOffset(
      offset: Offset.zero,
      position: position,
      hitTest: (result, transformed) =>
          chosen.hitTest(result, position: transformed),
    );
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    final chosen = _chosen;
    if (chosen != null) visitor(chosen);
  }
}
