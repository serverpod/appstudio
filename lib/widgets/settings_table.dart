import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

/// One line of a [SettingsTable].
class SettingsTableRow {
  const SettingsTableRow({
    required this.name,
    this.badge,
    required this.trailing,
  });

  final String name;

  /// Sits immediately after the name — a version, a status.
  final Widget? badge;

  /// Right-hand cell: a status badge, a size, an action.
  final Widget trailing;
}

/// A bordered card of two-column rows: what the thing is, and where it stands.
///
/// Shared by the toolchain setup dialog, Settings → Tools and Settings →
/// Providers. They ask the same question of different subjects, and drawing it
/// three times is what let the setup dialog offer a plain download where the
/// Tools tab said "Update needed".
class SettingsTable extends StatelessWidget {
  const SettingsTable({super.key, required this.rows});

  final List<SettingsTableRow> rows;

  /// Width of the right-hand column. Fixed: its contents are short badges,
  /// sizes and icon buttons, and letting them size themselves makes the column
  /// edge wander between rows.
  static const _trailingWidth = 120.0;

  @override
  Widget build(BuildContext context) {
    // `ShadTable.list` asserts on an empty child list, and empty is reachable —
    // `ToolchainController.create` falls back to an empty inventory when the
    // probe throws, rather than refusing to launch. Draw nothing instead of a
    // bare card; the surrounding pane is what explains an empty list.
    if (rows.isEmpty) return const SizedBox.shrink();

    final theme = ShadTheme.of(context);
    final rowHeight = theme.tableTheme.cellHeight ?? 48;

    return ShadCard(
      padding: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final nameWidth =
              (constraints.maxWidth - _trailingWidth).clamp(0.0, double.infinity);

          return SizedBox(
            height: rowHeight * rows.length,
            child: ShadTable.list(
              horizontalScrollPhysics: const NeverScrollableScrollPhysics(),
              columnSpanExtent: (index) => switch (index) {
                0 => FixedTableSpanExtent(nameWidth),
                _ => const FixedTableSpanExtent(_trailingWidth),
              },
              children: [
                for (final row in rows)
                  [
                    ShadTableCell(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              row.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.muted,
                            ),
                          ),
                          if (row.badge != null) ...[
                            const ShadGap(1.5),
                            row.badge!,
                          ],
                        ],
                      ),
                    ),
                    ShadTableCell(
                      alignment: Alignment.centerRight,
                      child: row.trailing,
                    ),
                  ],
              ],
            ),
          );
        },
      ),
    );
  }
}

/// The version badge used by every tool row.
///
/// [replacing] is the version already on this Mac when one was found and
/// rejected, rendered as `1.15.13 → 1.18.4`. Without it a too-old copy is
/// indistinguishable from nothing installed, and "OpenCode 1.18.4 — 45 MB"
/// beside a working `opencode` command reads as a failed detection.
Widget versionBadge(Object version, {Object? replacing}) => ShadBadge.secondary(
      child: Text(replacing == null ? '$version' : '$replacing → $version'),
    );
