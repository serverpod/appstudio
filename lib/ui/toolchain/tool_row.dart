import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../theme/app_theme.dart';
import '../../toolchain/install_progress.dart';
import '../../toolchain/tool_status.dart';
import '../../util/pretty_path.dart';
import '../../widgets/determinate_progress.dart';

/// One tool in the Tools Manager: where it came from, whether it is usable,
/// and — once installs land — what can be done about it.
class ToolRow extends StatelessWidget {
  const ToolRow({
    super.key,
    required this.status,
    required this.requirement,
    this.actions = const [],
    this.progress,
  });

  final ToolStatus status;

  /// Effective version requirement, e.g. `>=4.0.0-beta.1 <4.1.0`.
  final String requirement;
  final List<Widget> actions;

  /// Replaces the action row while this tool is installing.
  final ToolProgress? progress;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final resolved = status.resolved;
    final rejected = status.bestRejected;

    final (statusText, statusColor) = switch (resolved) {
      final r? => ('Ready', scheme.success),
      null when rejected?.fitness == ToolFitness.wrongVersion => (
          'Update needed',
          scheme.warning,
        ),
      _ => ('Not installed', scheme.destructive),
    };

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.muted.withValues(alpha: 0.45),
        borderRadius: theme.radii.md,
        border: Border.all(color: scheme.border.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          status.spec.displayName,
                          style: theme.textTheme.small
                              .copyWith(fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (resolved != null) ...[
                        const SizedBox(width: 8),
                        _SourceBadge(source: resolved.source),
                      ],
                    ],
                  ),
                ),
                Text(
                  statusText,
                  style: theme.textTheme.muted.copyWith(
                    fontSize: 11,
                    color: statusColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _detail(resolved, rejected),
              style: theme.textTheme.muted.copyWith(
                fontFamily: kMacMonoFont,
                fontSize: 10.5,
                height: 1.4,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              // A `*` range means "any real one will do" — the qualification is
              // that it is not a CLT stub, not a version.
              requirement == '*' ? 'Any version' : 'Requires $requirement',
              style: theme.textTheme.muted.copyWith(fontSize: 10.5),
            ),
            if (progress != null && !progress!.phase.isTerminal) ...[
              const SizedBox(height: 8),
              DeterminateProgress(
                fraction: progress!.fraction,
                caption: progress!.phase.label,
              ),
            ] else if (actions.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(children: actions),
            ],
          ],
        ),
      ),
    );
  }

  String _detail(ToolCandidate? resolved, ToolCandidate? rejected) {
    if (resolved != null) {
      final version = resolved.detectedVersion?.toString() ?? 'unknown version';
      final path = resolved.executable;
      return path == null ? version : '$version · ${prettyPath(path)}';
    }
    if (rejected?.reason != null) {
      final path = rejected!.executable;
      return path == null
          ? rejected.reason!
          : '${rejected.reason!} · ${prettyPath(path)}';
    }
    return 'Not found on this Mac.';
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.source});

  final ToolSource source;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    // Managed is the normal case, so it gets the quietest treatment; host and
    // dev repo are worth noticing because they are not ours to update.
    final outlined = source != ToolSource.managed;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: outlined ? Colors.transparent : scheme.muted,
        borderRadius: theme.radii.full,
        border: Border.all(color: scheme.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        child: Text(
          source.label,
          style: theme.textTheme.muted.copyWith(
            fontSize: 10,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
