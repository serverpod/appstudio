/// Fakes for the runner: a log filled with what a real one says, and the
/// actions the toolbar and the log pane send.
library;

import 'dart:async';

import 'package:appstudio/runner/runner_actions_view.dart';
import 'package:appstudio/runner/runner_log.dart';
import 'package:appstudio/runner/runner_protocol.dart';
import 'package:flutter/foundation.dart';

/// Runner actions that answer after a moment, in whatever state they are
/// built in.
class FakeRunnerActions extends ChangeNotifier implements RunnerActionsView {
  FakeRunnerActions({
    this.canHotReload = true,
    this.canMigrate = true,
    this.runningAction,
    this.failedAction,
    this.actionError,
    this.migrationResult = const MigrationResult(
      message: 'Migration created: migrations/20261007181530581',
      created: true,
    ),
    this.delay = const Duration(milliseconds: 900),
  });

  @override
  bool canHotReload;

  @override
  bool canMigrate;

  @override
  RunnerAction? runningAction;

  @override
  RunnerAction? failedAction;

  @override
  String? actionError;

  /// What create migration answers when not forced.
  MigrationResult migrationResult;

  final Duration delay;

  /// Every action asked for, in order, with `force` noted.
  final calls = <String>[];

  Future<T> _run<T>(RunnerAction action, T result) async {
    runningAction = action;
    failedAction = null;
    actionError = null;
    notifyListeners();
    await Future<void>.delayed(delay);
    runningAction = null;
    notifyListeners();
    return result;
  }

  @override
  Future<void> hotReload() async {
    calls.add('hotReload');
    await _run(RunnerAction.hotReload, null);
  }

  @override
  Future<void> hotRestart() async {
    calls.add('hotRestart');
    await _run(RunnerAction.hotRestart, null);
  }

  @override
  Future<MigrationResult?> createMigration({bool force = false}) {
    calls.add(force ? 'createMigration(force)' : 'createMigration');
    return _run(
      RunnerAction.createMigration,
      force
          ? const MigrationResult(
              message: 'Migration created: migrations/20261007181530581',
              created: true,
            )
          : migrationResult,
    );
  }

  @override
  Future<MigrationResult?> createRepairMigration({bool force = false}) {
    calls.add(force ? 'createRepairMigration(force)' : 'createRepairMigration');
    return _run(
      RunnerAction.createRepairMigration,
      const MigrationResult(message: 'Repair migration created.', created: true),
    );
  }

  @override
  Future<void> applyMigrations() async {
    calls.add('applyMigrations');
    await _run(RunnerAction.applyMigrations, null);
  }
}

/// What a runner refuses to create without `force`, in its own words.
const refusedMigration = MigrationResult(
  message: 'Migration aborted due to the following warnings:\n'
      'Column "nickname" of table "player" will be dropped.\n'
      'Table "legacy_score" will be dropped.',
  abortedForWarnings: true,
  isError: true,
);

const sampleAppId = 'demo';

/// A log as a fresh project leaves it: pub get, the runner's startup
/// operations, the pod booting, and the Flutter app launching.
///
/// [failure] adds a server error with a stack trace. [launching] leaves the
/// app mid-launch with its operation still running.
RunnerLog sampleRunnerLog({
  bool failure = false,
  bool launching = false,
  bool empty = false,
}) {
  final log = RunnerLog();
  if (empty) return log;
  final start = DateTime.now().subtract(const Duration(minutes: 2));
  DateTime at(int seconds) => start.add(Duration(seconds: seconds));

  for (final line in const [
    'dart pub get (demo)',
    'Resolving dependencies in `~/Projects/demo`...',
    'Got dependencies in `~/Projects/demo`!',
    'serverpod runner start',
  ]) {
    log.addLocal(line, time: start);
  }

  RunnerLogRecord record(
    int second,
    String message, {
    RunnerLogLevel level = RunnerLogLevel.info,
    String? scope,
    String? error,
    String? stackTrace,
  }) =>
      RunnerLogRecord(
        time: at(second),
        level: level,
        message: message,
        scope: scope,
        error: error,
        stackTrace: stackTrace,
      );

  RunnerOperation operation(int second, String label, int ms) =>
      RunnerOperation(
        label: label,
        success: true,
        duration: Duration(milliseconds: ms),
        completedAt: at(second),
      );

  log.applySnapshot(
    RunnerSnapshot(
      stage: RunnerStage.running,
      canLaunchFlutterApps: true,
      flutterApps: const [
        FlutterAppConfig(
          id: sampleAppId,
          name: 'Demo app',
          autoLaunch: true,
          device: 'web-server',
        ),
      ],
      runningFlutterApps: launching ? const {} : const {sampleAppId},
      launchingFlutterApps: launching ? const {sampleAppId} : const {},
      flutterAppUrls: launching
          ? const {}
          : const {sampleAppId: 'http://localhost:49301'},
      activeOperations: [
        if (launching)
          ActiveOperation(
            id: 'launch',
            label: 'Launching Demo app (first run may take 30-60s)',
            startedAt: DateTime.now().subtract(const Duration(seconds: 17)),
          ),
      ],
      flutterLines: {
        sampleAppId: [
          'Resolving dependencies in `~/Projects/demo`...',
          'Got dependencies in `~/Projects/demo`!',
          'Launching lib/main.dart on Web Server in debug mode...',
          if (!launching) ...[
            'lib/main.dart is being served at http://localhost:49301',
            'Debug service listening on ws://127.0.0.1:49358/VqYfrEzEiO8=/ws',
            'A Dart VM Service on Web Server is available at: '
                'http://127.0.0.1:49358/VqYfrEzEiO8=',
          ],
        ],
      },
      serverItems: [
        record(1, 'Starting server in watch mode...'),
        operation(1, 'Initializing analyzers', 60),
        operation(6, 'Analyzing changes', 4522),
        operation(6, 'Generating code', 102),
        operation(9, 'Running build hooks', 2895),
        operation(14, 'Compiling server', 4862),
        record(
          14,
          'Flutter VM service proxy listening on '
          'http://127.0.0.1:49265/OzZ7eOfsChyYf1_oA-g0eA=/',
        ),
        record(
          15,
          'The Dart VM service is listening on http://127.0.0.1:49269/',
          scope: 'Starting server',
        ),
        operation(15, 'Starting server', 413),
        record(15, 'Applied database migration: 20261007181530581'),
        record(15, 'WebServer: Webserver listening on http://localhost:8082'),
        record(16, 'Registration code for ada@example.com: <48775957>'),
        if (!launching) ...[
          operation(46, 'Launching Demo app (first run may take 30-60s)', 32343),
          record(46, 'Demo app running at http://localhost:49301'),
          operation(59, 'Connecting to Demo app VM service', 12971),
        ],
        if (failure) ...[
          record(
            80,
            'Internal server error. Failed to call endpoint greeting.hello',
            level: RunnerLogLevel.error,
            scope: 'greeting.hello',
            error: "Null check operator used on a null value",
            stackTrace: '#0      GreetingEndpoint.hello '
                '(package:demo_server/src/greetings/greeting_endpoint.dart:18:31)\n'
                '#1      _GreetingEndpointDispatch.call '
                '(package:demo_server/src/generated/endpoints.dart:44:12)\n'
                '#2      Server._handleEndpointCall '
                '(package:serverpod/src/server/server.dart:512:17)',
          ),
          record(
            81,
            'Slow query: SELECT * FROM "greeting" took 812ms',
            level: RunnerLogLevel.warning,
            scope: 'greeting.hello',
          ),
        ],
      ],
    ),
  );
  return log;
}
