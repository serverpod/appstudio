import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../runner/runner_actions_view.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/dialog_body.dart';
import '../../widgets/menu_item_tile.dart';

/// The log pane's Migrations menu: create a migration from the models, apply
/// pending ones, or create a repair migration — the runner's own commands,
/// with no server restart.
///
/// The outcome comes back as a toast in the runner's own words; the operation
/// itself also lands in the log with its duration. A migration the runner
/// refused for warnings — typically one that would drop data — is offered
/// again with `force`, behind a confirmation that quotes the warning.
class MigrationsMenu extends StatefulWidget {
  const MigrationsMenu({super.key, required this.actions});

  final RunnerActionsView actions;

  @override
  State<MigrationsMenu> createState() => _MigrationsMenuState();
}

class _MigrationsMenuState extends State<MigrationsMenu> {
  final _popover = ShadPopoverController();

  @override
  void dispose() {
    _popover.dispose();
    super.dispose();
  }

  RunnerActionsView get _actions => widget.actions;

  void _run(Future<void> Function() action) {
    _popover.hide();
    unawaited(action());
  }

  Future<void> _create({required bool repair, bool force = false}) async {
    final result = repair
        ? await _actions.createRepairMigration(force: force)
        : await _actions.createMigration(force: force);
    if (!mounted) return;
    final kind = repair ? 'repair migration' : 'migration';
    if (result == null) {
      _toast(
        'Could not create the $kind',
        _actions.actionError ?? 'The runner did not answer.',
        destructive: true,
      );
      return;
    }
    if (result.abortedForWarnings && !force) {
      final confirmed = await showAppDialog<bool>(
        context: context,
        builder: (context) => ForceMigrationDialog(
          kind: kind,
          message: result.message,
        ),
      );
      if (confirmed ?? false) await _create(repair: repair, force: true);
      return;
    }
    if (result.isError) {
      _toast('Could not create the $kind', result.message, destructive: true);
    } else if (result.created) {
      _toast('Created a $kind', result.message);
    } else {
      _toast('No $kind needed', result.message);
    }
  }

  Future<void> _apply() async {
    await _actions.applyMigrations();
    if (!mounted) return;
    if (_actions.failedAction == RunnerAction.applyMigrations) {
      _toast(
        'Could not apply migrations',
        _actions.actionError ?? '',
        destructive: true,
      );
    } else {
      _toast('Migrations applied', 'The database is up to date.');
    }
  }

  void _toast(String title, String message, {bool destructive = false}) {
    final toaster = ShadToaster.maybeOf(context);
    if (toaster == null) return;
    final description = message.trim().isEmpty ? null : Text(message.trim());
    toaster.show(
      destructive
          ? ShadToast.destructive(
              title: Text(title),
              description: description,
            )
          : ShadToast(title: Text(title), description: description),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _actions,
      builder: (context, _) {
        final running = _actions.runningAction;
        final busy = running?.isMigration ?? false;
        final enabled = _actions.canMigrate && running == null;

        return ShadPopover(
          controller: _popover,
          padding: const EdgeInsets.all(4),
          popover: (context) => SizedBox(
            width: 220,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                MenuItemTile(
                  icon: LucideIcons.filePlus,
                  label: 'Create migration',
                  onTap: () => _run(() => _create(repair: false)),
                ),
                MenuItemTile(
                  icon: LucideIcons.databaseZap,
                  label: 'Apply migrations',
                  onTap: () => _run(_apply),
                ),
                MenuItemTile(
                  icon: LucideIcons.wrench,
                  label: 'Create repair migration',
                  onTap: () => _run(() => _create(repair: true)),
                ),
              ],
            ),
          ),
          child: ShadTooltip(
            builder: (context) => Text(
              busy
                  ? '${running!.label}…'
                  : _actions.canMigrate
                      ? 'Create and apply database migrations'
                      : 'Migrations are available once the server is up',
            ),
            child: ShadGestureDetector(
              child: ShadButton.outline(
                size: ShadButtonSize.sm,
                enabled: enabled,
                onPressed: enabled ? _popover.toggle : null,
                leading: busy
                    ? const ShadSpinner(size: 14)
                    : const Icon(LucideIcons.database, size: 14),
                trailing: const Icon(LucideIcons.chevronDown, size: 14),
                child: const Text('Migrations'),
              ),
            ),
          ),
        );
      },
    );
  }
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
