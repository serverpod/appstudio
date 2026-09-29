import 'package:flutter/material.dart';
import 'package:shad/shad.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../session/external_editors_view.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialog.dart';

/// Set once the user ticks "Don't show this again".
const _kDismissedKey = 'project.started_notice_dismissed';

/// Screenshot of Cursor's MCP toggles, shown with the tip below.
const _kCursorSetupImage = 'assets/cursor-setup.png';

/// What the user did with the notice.
@immutable
class ProjectStartedResult {
  const ProjectStartedResult({
    required this.dismissForever,
    required this.openEditor,
  });

  final bool dismissForever;

  /// Set when the user pressed Open in …, rather than Dismiss.
  final ExternalEditor? openEditor;
}

/// Says the project is up and points at the editor to build it in.
///
/// Shown once the whole stack is running — the moment the "Starting your
/// project" notice was covering. Skipped entirely if the user has turned it
/// off.
Future<void> maybeShowProjectStartedNotice(
  BuildContext context, {
  required ExternalEditorsView editors,
}) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_kDismissedKey) ?? false) return;
  if (!context.mounted) return;

  final result = await showAppDialog<ProjectStartedResult>(
    context: context,
    // The buttons are the only way out, so a stray click on the barrier cannot
    // throw away a ticked "don't show this again".
    barrierDismissible: false,
    builder: (context) => ProjectStartedDialog(editor: featuredEditor(editors)),
  );
  if (result == null) return;

  if (result.dismissForever) {
    await prefs.setBool(_kDismissedKey, true);
  }
  // Opening is the caller's job for the same reason the preference is: the
  // dialog stays free of anything that touches the filesystem.
  final editor = result.openEditor;
  if (editor != null) await editors.open(editor);
}

/// The one editor the notice names and offers a button for, or null when the
/// project has none we can open.
///
/// Deliberately one and not all of them. The notice is a first step — "here is
/// where you go next" — and a row of equally weighted buttons is a decision,
/// not a next step. The toolbar carries the full set for anyone who wants the
/// other one.
ExternalEditor? featuredEditor(ExternalEditorsView editors) =>
    editors.editors.isEmpty ? null : editors.editors.first;

/// Pops a [ProjectStartedResult]; persisting and opening are the caller's job,
/// which keeps this widget free of `dart:io` and easy to show in Widgetbook.
class ProjectStartedDialog extends StatefulWidget {
  const ProjectStartedDialog({super.key, required this.editor});

  /// Null when nothing this project was configured for can be opened here, in
  /// which case the copy falls back to "your editor" and there is no button —
  /// naming an editor we cannot launch would be an offer we can't keep.
  final ExternalEditor? editor;

  @override
  State<ProjectStartedDialog> createState() => _ProjectStartedDialogState();
}

class _ProjectStartedDialogState extends State<ProjectStartedDialog> {
  bool _dontShowAgain = false;

  void _close({ExternalEditor? open}) => Navigator.of(
    context,
  ).pop(ProjectStartedResult(dismissForever: _dontShowAgain, openEditor: open));

  @override
  Widget build(BuildContext context) {
    final editor = widget.editor;

    return ShadDialog.alert(
      // Wider than the default so the Cursor screenshot below is legible
      // rather than thumbnail-sized.
      constraints: const BoxConstraints(maxWidth: 520),
      title: const Text('Your project has started'),
      description: Text(
        'Open the project in ${editor?.label ?? 'your editor'} to start '
        'building. Your app will be updated here in real time.',
      ),
      actionsMainAxisSize: MainAxisSize.max,
      actionsMainAxisAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        // Flexible so the row cannot overflow: this one carries two buttons,
        // and the wider of them is named after whatever editor turns up.
        Flexible(
          child: ShadCheckbox(
            value: _dontShowAgain,
            onChanged: (v) => setState(() => _dontShowAgain = v),
            label: Text("Don't show this again", style: kWeightMedium),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ShadButton.outline(onPressed: _close, child: const Text('Dismiss')),
            if (editor != null) ...[
              const ShadGap(2),
              ShadButton(
                onPressed: () => _close(open: editor),
                child: Text('Open in ${editor.label}'),
              ),
            ],
          ],
        ),
      ],
      child: editor?.id == 'cursor' ? const _CursorMcpTip() : null,
    );
  }
}

/// Cursor ships the MCP servers `serverpod create --ide cursor` configured, but
/// leaves them switched off — so the agent starts without the Serverpod and
/// Dart tools unless the user turns them on. The screenshot is here because the
/// toggles live behind a search field that is hard to describe in a sentence.
class _CursorMcpTip extends StatelessWidget {
  const _CursorMcpTip();

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return ShadAlert(
      icon: const Icon(LucideIcons.lightbulb),
      description: const Text(
        'To get the best experience, enable the Serverpod and Dart MCP '
        'servers in Cursor.',
      ),
      bottom: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: ClipRRect(
          borderRadius: theme.radii.md,
          child: Image.asset(
            _kCursorSetupImage,
            // The asset is 842px wide; without this it would ask for 842
            // logical pixels and blow the dialog open.
            width: double.infinity,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
