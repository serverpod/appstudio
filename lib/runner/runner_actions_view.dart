import 'package:flutter/foundation.dart';

import 'runner_protocol.dart';

/// The commands App Studio sends to a running runner.
enum RunnerAction {
  hotReload('Hot reload'),
  hotRestart('Hot restart'),
  createMigration('Create migration'),
  createRepairMigration('Create repair migration'),
  applyMigrations('Apply migrations');

  const RunnerAction(this.label);

  final String label;

  bool get isMigration => switch (this) {
        createMigration || createRepairMigration || applyMigrations => true,
        hotReload || hotRestart => false,
      };
}

/// Everything the toolbar's reload buttons and the log pane's migration menu
/// need, and nothing that touches a socket.
///
/// `ServerpodProcessController` implements this directly; the widgets import
/// only this file, so every state can be drawn in Widgetbook and pinned in a
/// widget test without a runner behind it.
///
/// One action runs at a time. The runner would accept a second — but a hot
/// restart racing a migration is not something anyone means to ask for, and a
/// button that queues silently reads as one that did nothing.
abstract interface class RunnerActionsView implements Listenable {
  /// A runner is attached and its server is up, so a reload has something to
  /// reload.
  bool get canHotReload;

  /// A runner is attached and has a stack — running, or failed to build, which
  /// is often exactly when a migration is wanted.
  bool get canMigrate;

  /// The action in flight, or null.
  RunnerAction? get runningAction;

  /// The last action that failed, and why. Cleared by the next action.
  RunnerAction? get failedAction;
  String? get actionError;

  /// Hot-reloads the server isolate, then every running Flutter app. Keeps
  /// in-memory state, so it does not pick up a change to `main()`.
  Future<void> hotReload();

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
