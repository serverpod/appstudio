import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../widgets/app_dialog.dart';
import '../widgets/dialog_body.dart';

/// Help → About App Studio on Windows, where there is no system About panel
/// to name the version (macOS gets AppKit's, from the bundle).
Future<void> showAboutAppStudio(
  BuildContext context, {
  required String versionLabel,
}) =>
    showAppDialog<void>(
      context: context,
      builder: (context) => AboutAppStudioDialog(versionLabel: versionLabel),
    );

class AboutAppStudioDialog extends StatelessWidget {
  const AboutAppStudioDialog({super.key, required this.versionLabel});

  /// `UpdateState.versionLabel`: "Version 0.2.3 (build 22)".
  final String versionLabel;

  @override
  Widget build(BuildContext context) {
    return ShadDialog.alert(
      title: const Text('App Studio'),
      description: Text('$versionLabel\n© 2026 Serverpod AB'),
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
