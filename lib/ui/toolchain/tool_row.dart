import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../toolchain/install_progress.dart';
import '../../toolchain/tool_status.dart';
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
    final body = _body();

    return ShadCard(
      backgroundColor: scheme.muted,
      title: Text(status.spec.displayName, overflow: TextOverflow.ellipsis),
      // `action`, not `trailing`: trailing sits beside the card's whole content
      // column and would squeeze the body.
      action: ShadRow(spacing: 1.5, children: _badges(resolved, rejected)),
      description: Text(
        // A `*` range means "any real one will do" — the qualification is that
        // it is not a CLT stub, not a version.
        requirement == '*' ? 'Any version' : 'Requires $requirement',
        style: theme.textTheme.muted,
      ),
      child: body,
    );
  }

  /// The version, then where it came from — or why it is unusable.
  ///
  /// This replaces the old status line and install path. The path was the
  /// longest thing on the card and answered a question nobody was asking: what
  /// matters is whether a usable version is present and who updates it.
  List<Widget> _badges(ToolCandidate? resolved, ToolCandidate? rejected) {
    final version = (resolved ?? rejected)?.detectedVersion;
    return [
      if (version != null) ShadBadge(child: Text('$version')),
      if (resolved != null)
        // Outline, not `secondary`: slate defines `secondary` and `muted` as
        // the same colour, so a secondary badge is invisible on this card.
        ShadBadge.outline(child: Text(resolved.source.label))
      else if (rejected?.fitness == ToolFitness.wrongVersion)
        // Outline, not destructive: a too-old host tool is an update, not a
        // failure — the version badge beside it already says which one is
        // there. Destructive is reserved for "there is nothing to run".
        const ShadBadge.outline(child: Text('Update needed'))
      else
        const ShadBadge.destructive(child: Text('Missing')),
    ];
  }

  Widget? _body() {
    if (progress case final p? when !p.phase.isTerminal) {
      return DeterminateProgress(fraction: p.fraction, caption: p.phase.label);
    }
    if (actions.isEmpty) return null;
    return ShadRow(spacing: 2, children: actions);
  }
}
