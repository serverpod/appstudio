import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../theme/app_theme.dart';
import '../widgets/app_dialog.dart';
import '../widgets/dialog_body.dart';

/// Toolbar button for publishing the open project to Serverpod Cloud.
///
/// App Studio does not run the deploy itself yet: the button opens
/// [PublishToCloudDialog], which tells the user the one command that does.
/// Outline with a label, at the same height as the icon buttons beside it so
/// the toolbar's right-hand cluster sits on one line.
class PublishToCloudButton extends StatelessWidget {
  const PublishToCloudButton({super.key});

  @override
  Widget build(BuildContext context) {
    return ShadButton.outline(
      height: kToolbarIconButtonSize,
      size: ShadButtonSize.sm,
      onPressed: () => unawaited(showPublishToCloudDialog(context)),
      leading: const Icon(LucideIcons.cloudUpload, size: 16),
      child: const Text('Publish to Cloud'),
    );
  }
}

/// Raises [PublishToCloudDialog]. Dismissible every way — it reports something
/// rather than asking for a decision, so nothing is lost to a stray click on
/// the barrier.
Future<void> showPublishToCloudDialog(BuildContext context) =>
    showAppDialog<void>(
      context: context,
      builder: (context) => const PublishToCloudDialog(),
    );

/// Points the user at `serverpod cloud launch`, run from their own terminal in
/// the project directory.
///
/// `ShadDialog.alert` is the variant with no close X — OK is the one way out —
/// and the body copy rides in `description` so it lands on `textTheme.muted`
/// rather than the cramped label role.
class PublishToCloudDialog extends StatelessWidget {
  const PublishToCloudDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ShadDialog.alert(
      title: const Text('Publish to Serverpod Cloud'),
      description: Text.rich(
        TextSpan(
          children: [
            const TextSpan(
              text:
                  'To publish this app to Serverpod Cloud, open your Terminal '
                  'app, change directory to your project directory, and run ',
            ),
            TextSpan(
              text: 'serverpod cloud launch',
              style: TextStyle(
                fontFamily: kMacMonoFont,
                color: theme.colorScheme.foreground,
              ),
            ),
            const TextSpan(text: '.'),
          ],
        ),
      ),
      actions: [
        ShadButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
      child: const DialogBody(),
    );
  }
}
