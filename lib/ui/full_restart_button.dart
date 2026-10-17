import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shad/shad.dart';

import '../platform/shortcut_hint.dart';
import '../process/full_restart_view.dart';
import '../widgets/toolbar_action_button.dart';

/// Toolbar button that stops the server and starts it again.
///
/// Replaces the separate Start and Stop icons. They were two controls for one
/// question — "give me a fresh server" — and the pair invited the state that
/// actually breaks things: stopped on purpose, with a preview pane and an agent
/// still sitting there waiting for a server that is never coming back.
///
/// Also the recovery path: with the server stopped after a crash or a failed
/// compile there is nothing to stop, so it is a plain start.
class FullRestartButton extends StatelessWidget {
  const FullRestartButton({super.key, required this.process});

  final FullRestartView process;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: process,
      builder: (context, _) {
        final busy = process.isTransitioning;

        return ToolbarActionButton(
          label: 'Full Restart',
          icon: LucideIcons.refreshCcwDot,
          busy: busy,
          tooltip: busy
              ? 'Restarting the server…'
              : 'Full restart (${shortcutHint('R', shift: true)})',
          onPressed: process.canRestart
              ? () => unawaited(process.restart())
              : null,
        );
      },
    );
  }
}
