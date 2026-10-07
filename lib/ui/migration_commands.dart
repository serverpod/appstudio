import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../runner/runner_actions_view.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dialog.dart';
import '../widgets/dialog_body.dart';

/// The Server menu's migration commands: what runs, what is asked, and what
/// is reported. They live in the menu bar rather than in any pane, so they
/// take the navigator's context for the dialog and the toasts.
///
/// The outcome comes back as a toast in the runner's own words; each step also
/// lands in the server log as an operation with its duration.

/// Creates a migration from the models and applies whatever is pending — the
/// one thing a user means by "migrate", as one command (⌘M).
///
/// Applying runs even when no new migration was needed: a migration created
/// earlier, by hand or by `serverpod create-migration`, may still be pending,
/// and "the database matches the models" is the promise either way. A create
/// the runner refused for warnings — typically one that would drop data — is
/// offered again with `force` behind a confirmation quoting the warning, and
/// nothing is applied unless the user goes ahead.
Future<void> createAndApplyMigrations(
  BuildContext context,
  RunnerActionsView actions,
) async {
  if (!actions.canMigrate || actions.runningAction != null) return;

  var created = await actions.createMigration();
  if (!context.mounted) return;
  if (created != null && created.abortedForWarnings) {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) =>
          ForceMigrationDialog(kind: 'migration', message: created!.message),
    );
    if (!(confirmed ?? false) || !context.mounted) return;
    created = await actions.createMigration(force: true);
    if (!context.mounted) return;
  }
  if (created == null || created.isError) {
    _toast(
      context,
      'Could not create a migration',
      created?.message ?? actions.actionError ?? 'The runner did not answer.',
      destructive: true,
    );
    return;
  }

  await actions.applyMigrations();
  if (!context.mounted) return;
  if (actions.failedAction == RunnerAction.applyMigrations) {
    _toast(
      context,
      created.created
          ? 'Created a migration, but could not apply it'
          : 'Could not apply migrations',
      actions.actionError ?? '',
      destructive: true,
    );
    return;
  }
  _toast(
    context,
    created.created ? 'Migration created and applied' : 'Migrations applied',
    created.message,
  );
}

/// Creates a repair migration toward the latest migration, for a database that
/// has drifted from the migration history. Not applied: a repair is worth
/// reading first, and the runner's apply — Create and Apply Migrations — takes
/// pending repair migrations along with the rest.
Future<void> createRepairMigration(
  BuildContext context,
  RunnerActionsView actions,
) async {
  if (!actions.canMigrate || actions.runningAction != null) return;

  var result = await actions.createRepairMigration();
  if (!context.mounted) return;
  if (result != null && result.abortedForWarnings) {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => ForceMigrationDialog(
        kind: 'repair migration',
        message: result!.message,
      ),
    );
    if (!(confirmed ?? false) || !context.mounted) return;
    result = await actions.createRepairMigration(force: true);
    if (!context.mounted) return;
  }
  if (result == null || result.isError) {
    _toast(
      context,
      'Could not create a repair migration',
      result?.message ?? actions.actionError ?? 'The runner did not answer.',
      destructive: true,
    );
  } else if (result.created) {
    _toast(context, 'Created a repair migration', result.message);
  } else {
    _toast(context, 'No repair migration needed', result.message);
  }
}

void _toast(
  BuildContext context,
  String title,
  String message, {
  bool destructive = false,
}) {
  final toaster = ShadToaster.maybeOf(context);
  if (toaster == null) return;
  final description = message.trim().isEmpty ? null : Text(message.trim());
  toaster.show(
    destructive
        ? ShadToast.destructive(title: Text(title), description: description)
        : ShadToast(title: Text(title), description: description),
  );
}

/// Asks before creating a migration the runner stopped at warnings for.
///
/// The warning is quoted as the runner wrote it — it names the tables and
/// columns at risk, which is the one thing the user needs to decide.
class ForceMigrationDialog extends StatelessWidget {
  const ForceMigrationDialog({
    super.key,
    required this.kind,
    required this.message,
  });

  /// "migration" or "repair migration".
  final String kind;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return ShadDialog.alert(
      title: Text('Create the $kind anyway?'),
      description: const Text(
        'The migration was not created because of the warnings below. '
        'Creating it anyway may lose data when it is applied.',
      ),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ShadButton.destructive(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Create anyway'),
        ),
      ],
      child: DialogBody(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240),
          child: SingleChildScrollView(
            child: SelectableText(
              message.trim(),
              style: theme.textTheme.muted.copyWith(
                fontFamily: kMacMonoFont,
                fontSize: 12,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
