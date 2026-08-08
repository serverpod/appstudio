import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

/// Styling shared by [IconSegmentedControl] and [TextSegmentedControl].
///
/// Everything here resolves from the theme's tab tokens — the strip/segment
/// treatment `ShadTabs` uses — so both controls follow the active style preset
/// and radius the way a built-in component does, and neither has to invent a
/// color of its own.
///
/// Set `onMutedSurface` when the control sits on a muted pane header: the track
/// and selection colors swap, so the pair keeps the same contrast either way.

/// Fill of the strip segments sit in.
Color segmentTrackColor(ShadColorScheme scheme, bool onMutedSurface) =>
    onMutedSurface ? scheme.background : scheme.muted;

/// Fill of the selected segment — the inverse of the track.
Color segmentSelectedColor(ShadColorScheme scheme, bool onMutedSurface) =>
    onMutedSurface ? scheme.muted : scheme.background;

/// Decoration for one segment. Unselected segments are transparent, as in
/// `ShadTabs`; hover is carried by the foreground instead of a fill, so no
/// blend has to be invented for it.
BoxDecoration segmentDecoration(
  ShadThemeData theme, {
  required bool selected,
  required bool onMutedSurface,
}) =>
    BoxDecoration(
      color: selected
          ? segmentSelectedColor(theme.colorScheme, onMutedSurface)
          : Colors.transparent,
      borderRadius: theme.radii.resolve(theme.style.tabRadius),
      boxShadow: selected ? theme.style.tabSelectedShadow : null,
    );

/// Foreground for one segment: full strength when selected or hovered, muted
/// otherwise.
Color segmentForegroundColor(
  ShadColorScheme scheme, {
  required bool selected,
  required bool hovered,
}) =>
    selected || hovered ? scheme.foreground : scheme.mutedForeground;

/// The strip segments sit in — `ShadTabs`' list decoration.
class SegmentTrack extends StatelessWidget {
  const SegmentTrack({
    super.key,
    required this.onMutedSurface,
    required this.child,
  });

  final bool onMutedSurface;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: segmentTrackColor(theme.colorScheme, onMutedSurface),
        borderRadius: theme.radii.resolve(theme.style.tabsListRadius),
      ),
      padding: EdgeInsets.all(theme.style.tabsListPadding),
      child: child,
    );
  }
}
