import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shad/shad.dart';

import '../session/external_editors_view.dart';
import '../theme/app_theme.dart';

/// One “Open in …” button per external editor the open project was configured
/// for and that is actually installed.
///
/// Draws nothing at all when there are none, including the trailing gap — the
/// common case on a project set up with no external editor, where a stray 10px
/// would be the only trace of it.
class OpenInEditorButtons extends StatelessWidget {
  const OpenInEditorButtons({super.key, required this.editors});

  final ExternalEditorsView editors;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: editors,
      builder: (context, _) {
        final available = editors.editors;
        if (available.isEmpty) return const SizedBox.shrink();
        final canOpen = editors.canOpen;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final editor in available)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: _OpenInEditorButton(
                  editor: editor,
                  onPressed: canOpen
                      ? () => unawaited(editors.open(editor))
                      : null,
                ),
              ),
            const SizedBox(width: 6),
          ],
        );
      },
    );
  }
}

class _OpenInEditorButton extends StatelessWidget {
  const _OpenInEditorButton({required this.editor, required this.onPressed});

  final ExternalEditor editor;

  /// Null while the project is still starting.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final button = ShadButton.ghost(
      // Matches the icon buttons beside it, so the toolbar's right-hand cluster
      // sits on one line rather than stepping.
      height: kToolbarIconButtonSize,
      size: ShadButtonSize.sm,
      // `enabled` is what dims it — a null handler on its own leaves the button
      // inert but looking live, which reads as a broken click.
      enabled: onPressed != null,
      onPressed: onPressed,
      trailing: const Icon(LucideIcons.arrowUpRight, size: 14),
      child: Text('Open in ${editor.label}'),
    );

    if (onPressed != null) return button;

    // A disabled `ShadButton` puts its content behind an `AbsorbPointer`, which
    // eats the hover `ShadTooltip` listens for. The detector has to sit outside
    // it, or the one tooltip worth reading never opens.
    return ShadTooltip(
      builder: (context) => const Text('Waiting for your project to start'),
      child: ShadGestureDetector(child: button),
    );
  }
}
