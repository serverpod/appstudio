import 'package:flutter/foundation.dart';

import 'runner_protocol.dart';

/// The commands App Studio sends to a running runner.
enum RunnerAction {
  hotRestart('Hot restart'),
  createMigration('Create migration'),
  createRepairMigration('Create repair migration'),
  applyMigrations('Apply migrations');

  const RunnerAction(this.label);

  final String label;

  bool get isMigration => switch (this) {
        createMigration || createRepairMigration || applyMigrations => true,
        hotRestart => false,
      };
}

/// Everything the toolbar's Hot Restart button and the Server menu need, and
/// nothing that touches a socket.
///
/// There is no hot *reload* here on purpose: the runner watches the project and
/// hot-reloads on every save, so a button for it would only repeat what has
/// already happened.
///
/// `ServerpodProcessController` implements this directly; the widgets import
/// only this file, so every state can be drawn in Widgetbook and pinned in a
/// widget test without a runner behind it.
///
/// One action runs at a time. The runner would accept a second — but a hot
/// restart racing a migration is not something anyone means to ask for, and a
/// button that queues silently reads as one that did nothing.
abstract interface class RunnerActionsView implements Listenable {
  /// A runner is attached and its server is up, so a restart has something to
  /// restart.
  bool get canHotRestart;

  /// A runner is attached and has a stack — running, or failed to build, which
  /// is often exactly when a migration is wanted.
  bool get canMigrate;

  /// The action in flight, or null.
  RunnerAction? get runningAction;

  /// The last action that failed, and why. Cleared by the next action.
  RunnerAction? get failedAction;
  String? get actionError;

  /// Restarts the server process and hot-restarts every running Flutter app,
  /// then hard-reloads the preview.
  Future<void> hotRestart();

  /// Creates a migration from the model definitions without applying it.
  /// [force] creates it despite warnings, such as one that would lose data.
  /// Null when the runner could not be asked.
  Future<MigrationResult?> createMigration({bool force = false});

  /// Creates a repair migration toward the latest migration.
  Future<MigrationResult?> createRepairMigration({bool force = false});

  /// Applies pending migrations without restarting the server.
  Future<void> applyMigrations();
}
