import 'dart:async';
import 'dart:io';

import 'package:appstudio/preview/preview_phase.dart';
import 'package:appstudio/process/serverpod_process.dart';
import 'package:appstudio/runner/runner_actions_view.dart';
import 'package:appstudio/runner/runner_ownership.dart';
import 'package:appstudio/runner/runner_protocol.dart';
import 'package:appstudio/runner/server_status.dart';
import 'package:appstudio/session/project_session.dart';
import 'package:appstudio/toolchain/toolchain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_runner.dart';
import '../support/toolchain_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProjectSession session;
  late ServerpodProcessController process;
  late Directory scratch;
  final runners = <FakeRunner>[];
  var launches = 0;

  /// Stands a fake runner up the way `serverpod runner start` would, and
  /// reports the CLI as having exited cleanly once it answers.
  Future<RunnerLaunch> launcher({
    required Toolchain toolchain,
    required String serverDir,
  }) async {
    launches++;
    final runner = await FakeRunner.start(serverDir, pid: 5000 + launches);
    runners.add(runner);
    return RunnerLaunch(
      output: Stream.fromIterable([
        'Waiting for the runner (pid ${runner.pid}) to start...',
      ]),
      exitCode: Future.value(0),
      kill: () {},
    );
  }

  Future<void> until(bool Function() condition, {String? reason}) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out waiting for ${reason ?? 'condition'}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    scratch = await Directory.systemTemp.createTemp('appstudio_process');
    ownedRunnerRecordPathOverride = p.join(scratch.path, 'runner.json');
    launches = 0;
    session = ProjectSession();
    process = ServerpodProcessController(
      toolchains: await emptyToolchainController(),
      session: session,
      launcher: launcher,
      dependencies: (_, _, _) async {},
    );
  });

  tearDown(() async {
    await process.stop();
    process.dispose();
    for (final runner in runners) {
      await runner.close();
      final root = Directory(p.dirname(runner.serverDir));
      if (await root.exists()) await root.delete(recursive: true);
    }
    runners.clear();
    ownedRunnerRecordPathOverride = null;
    await scratch.delete(recursive: true);
  });

  /// A project with a runner already up, started by someone else.
  Future<FakeRunner> projectWithRunner({
    String stage = 'running',
    Map<String, Object?> snapshot = const {},
  }) async {
    final root = await FakeRunner.createProject();
    final runner = await FakeRunner.start(
      FakeRunner.serverDirOf(root),
      stage: stage,
      snapshot: snapshot,
    );
    runners.add(runner);
    return runner;
  }

  Future<void> open(FakeRunner runner) async {
    await session.openPath(p.dirname(runner.serverDir));
    await until(() => process.stage != null, reason: 'attach');
  }

  group('with no project', () {
    test('restart does nothing', () async {
      await process.restart();

      expect(process.state, ProcessState.idle);
      expect(process.isRestarting, isFalse);
    });

    test('Full Restart is offered stopped, but not without a project', () {
      expect(process.isStopped, isTrue);
      expect(process.isTransitioning, isFalse);
      expect(process.canRestart, isFalse);
    });

    test('a preview reload is declined, and nobody is notified', () {
      var notifications = 0;
      process.addListener(() => notifications++);
      final before = process.previewReloadToken;

      process.requestPreviewReload();

      expect(process.previewReloadToken, before);
      expect(notifications, 0);
    });
  });

  group('a runner someone else started', () {
    test('is attached to, not started again', () async {
      final runner = await projectWithRunner();

      await open(runner);

      expect(launches, 0);
      expect(process.ownsRunner, isFalse);
      expect(process.state, ProcessState.running);
      expect(runner.calls, contains('snapshot'));
    });

    test('is only detached from when the project closes', () async {
      final runner = await projectWithRunner();
      await open(runner);

      session.closeProject();
      await until(() => process.state == ProcessState.idle);

      expect(runner.calls, isNot(contains('stop')));
      expect(runner.isClosed, isFalse);
    });

    test('stopping it elsewhere leaves App Studio idle, not failed', () async {
      final runner = await projectWithRunner();
      await open(runner);

      await runner.stopRunner();
      await until(() => process.state == ProcessState.idle);

      expect(process.phase, PreviewPhase.idle);
      expect(process.error, isNull);
    });

    test('a crash is a failure', () async {
      final runner = await projectWithRunner();
      await open(runner);

      await runner.crash();
      await until(() => process.state == ProcessState.idle);

      expect(process.phase, PreviewPhase.failed);
      expect(process.error, contains('stopped unexpectedly'));
    });
  });

  group('a runner App Studio started', () {
    Future<FakeRunner> openFresh() async {
      final root = await FakeRunner.createProject();
      await session.openPath(root.path);
      await until(() => process.stage != null, reason: 'attach');
      return runners.single;
    }

    test('is launched when none is running, and recorded as ours', () async {
      final runner = await openFresh();

      expect(launches, 1);
      expect(process.ownsRunner, isTrue);
      final owned = await readOwnedRunner();
      expect(owned?.pid, runner.pid);
    });

    test('is stopped when the project closes', () async {
      final runner = await openFresh();

      session.closeProject();
      await until(() => process.state == ProcessState.idle);

      expect(runner.calls, contains('stop'));
      expect(await readOwnedRunner(), isNull);
    });

    test('Full Restart stops it and starts a new one', () async {
      final first = await openFresh();

      await process.restart();

      expect(first.calls, contains('stop'));
      expect(launches, 2);
      expect(process.state, ProcessState.running);
      expect(process.isRestarting, isFalse);
    });
  });

  group('the preview', () {
    test('loads the URL the runner publishes, then waits for the page',
        () async {
      final runner = await projectWithRunner(
        snapshot: {
          'flutterApps': [demoApp],
          'launchingFlutterApps': ['demo'],
        },
      );
      await open(runner);
      expect(process.previewReady, isFalse);
      expect(process.phase, PreviewPhase.loadingApp);

      runner.emit({
        'event': 'flutterAppState',
        'appId': 'demo',
        'running': true,
        'launching': false,
        'url': 'http://localhost:51234',
      });
      await until(() => process.previewReady);

      expect(process.previewUrl, Uri.parse('http://localhost:51234'));
      expect(process.phase, PreviewPhase.connecting);

      process.markPreviewLive();
      expect(process.phase, PreviewPhase.ready);
      expect(process.projectIsReady, isTrue);
    });

    test('a progress update without a URL keeps the last one', () async {
      final runner = await projectWithRunner(
        snapshot: {
          'flutterApps': [demoApp],
          'runningFlutterApps': ['demo'],
          'flutterAppUrls': {'demo': 'http://localhost:51234'},
        },
      );
      await open(runner);
      process.markPreviewLive();

      runner.emit({
        'event': 'flutterAppState',
        'appId': 'demo',
        'running': true,
        'launching': false,
        'launchStage': 'Performing hot restart...',
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(process.previewUrl, Uri.parse('http://localhost:51234'));
      expect(process.phase, PreviewPhase.ready);
    });

    test('an app that is not auto-launched is launched for the preview',
        () async {
      final runner = await projectWithRunner(
        snapshot: {
          'flutterApps': [
            {...demoApp, 'autoLaunch': false},
          ],
        },
      );

      await open(runner);
      await until(() => runner.calls.contains('launchFlutterApp'));
    });
  });

  group('runner stages', () {
    test('starting, then running, as the runner reports it', () async {
      final runner = await projectWithRunner(stage: 'starting');
      await open(runner);
      expect(process.state, ProcessState.starting);
      expect(process.phase, PreviewPhase.waitingForServer);
      expect(process.canHotRestart, isFalse);

      runner.emit({'event': 'stage', 'stage': 'running'});
      await until(() => process.state == ProcessState.running);

      expect(process.canHotRestart, isTrue);
    });

    test('a failed build is a failure Full Restart retries', () async {
      final runner = await projectWithRunner(stage: 'degraded');
      await open(runner);

      expect(process.phase, PreviewPhase.failed);
      expect(process.error, contains('failed to build'));
      expect(process.canMigrate, isTrue);
      expect(process.canHotRestart, isFalse);

      await process.restart();

      expect(runner.calls, contains('retryStart'));
      expect(runner.calls, isNot(contains('stop')));
    });
  });

  group('actions', () {
    test('hot restart hard-reloads the preview once it is done', () async {
      final runner = await projectWithRunner(
        snapshot: {
          'flutterApps': [demoApp],
          'runningFlutterApps': ['demo'],
          'flutterAppUrls': {'demo': 'http://localhost:51234'},
        },
      );
      await open(runner);
      final before = process.previewReloadToken;

      await process.hotRestart();

      expect(runner.calls, contains('hotRestart'));
      expect(process.previewReloadToken, before + 1);
      expect(process.runningAction, isNull);
    });

    test('a refused hot restart is reported and does not reload', () async {
      final runner = await projectWithRunner();
      runner.failures['hotRestart'] = 'Compilation failed.';
      await open(runner);
      final before = process.previewReloadToken;

      await process.hotRestart();

      expect(process.failedAction, RunnerAction.hotRestart);
      expect(process.actionError, 'Compilation failed.');
      expect(process.previewReloadToken, before);
    });

    test('a migration refused for warnings comes back for a force', () async {
      final runner = await projectWithRunner();
      runner.replies['createMigration'] = (params) => params['force'] == true
          ? {'message': 'Created.', 'created': true}
          : {
              'message': 'Column "nickname" will be dropped.',
              'abortedForWarnings': true,
              'isError': true,
            };
      await open(runner);

      final refused = await process.createMigration();
      expect(refused?.abortedForWarnings, isTrue);
      // Not an error the toolbar should colour: it is a question.
      expect(process.failedAction, isNull);

      final forced = await process.createMigration(force: true);
      expect(forced?.created, isTrue);
    });
  });

  group('the log', () {
    test('mirrors the snapshot, then every event', () async {
      final runner = await projectWithRunner(
        snapshot: {
          'serverEntries': [
            {
              'type': 'operation',
              'label': 'Compiling server',
              'success': true,
              'durationMs': 4862,
              'completedAt': '2026-10-07T20:21:31.884122',
            },
          ],
        },
      );
      await open(runner);

      runner.emit(logEvent('Webserver listening', level: 'info'));
      await until(
        () => process.log.serverItems
            .whereType<RunnerLogRecord>()
            .any((r) => r.message == 'Webserver listening'),
      );

      final items = process.log.serverItems.whereType<RunnerOperation>();
      expect(items.single.label, 'Compiling server');
      expect(
        process.log.serverItems.whereType<RunnerLogRecord>().map((r) => r.message),
        contains('Webserver listening'),
      );
    });

    test('picks up the registration code the server logs', () async {
      final runner = await projectWithRunner();
      await open(runner);

      runner.emit(
        logEvent('Registration code for a@b.se: <48775957>'),
      );
      await until(() => process.registrationCode != null);

      expect(process.registrationCode, '48775957');

      runner.emit(logEvent('Registration code for c@d.se: <22222222>'));
      await until(() => process.registrationCode == '22222222');

      process.dismissRegistrationCode();
      expect(process.registrationCode, isNull);
    });

    test('a busy log does not rebuild everything listening to the process',
        () async {
      final runner = await projectWithRunner();
      await open(runner);
      var notifications = 0;
      process.addListener(() => notifications++);

      for (var i = 0; i < 20; i++) {
        runner.emit(logEvent('line $i'));
      }
      await until(() => process.log.serverItems.length >= 20);

      expect(notifications, 0);
    });
  });

  group('server status', () {
    test('stopped with no project', () {
      expect(process.serverStatus().kind, ServerStatusKind.stopped);
      expect(process.serverStatus().message, 'Stopped');
    });

    test('running once the app is live in the preview', () async {
      final runner = await projectWithRunner(
        snapshot: {
          'flutterApps': [demoApp],
          'runningFlutterApps': ['demo'],
          'flutterAppUrls': {'demo': 'http://localhost:51234'},
        },
      );
      await open(runner);
      expect(process.serverStatus().kind, ServerStatusKind.busy);
      expect(process.serverStatus().message, 'Loading the app');

      process.markPreviewLive();

      expect(process.serverStatus(), const ServerStatus.running());
    });

    test('names the latest operation, without the terminal dots', () async {
      final runner = await projectWithRunner(stage: 'starting');
      await open(runner);
      final started = DateTime.now().subtract(const Duration(seconds: 3));
      runner
        ..emit({
          'event': 'operationStarted',
          'id': 'a',
          'label': 'Analyzing changes',
          'startedAt': started.toIso8601String(),
        })
        ..emit({
          'event': 'operationStarted',
          'id': 'b',
          'label': 'Compiling server...',
          'startedAt': started.add(const Duration(seconds: 1)).toIso8601String(),
        });
      await until(() => process.log.activeOperations.length == 2);

      final status = process.serverStatus();
      expect(status.kind, ServerStatusKind.busy);
      expect(status.message, 'Compiling server');
    });

    test('an operation too young to show is waited out, not shown', () async {
      final runner = await projectWithRunner(
        snapshot: {
          'flutterApps': [demoApp],
          'runningFlutterApps': ['demo'],
          'flutterAppUrls': {'demo': 'http://localhost:51234'},
        },
      );
      await open(runner);
      process.markPreviewLive();
      final now = DateTime.now();
      runner.emit({
        'event': 'operationStarted',
        'id': 'scope',
        'label': 'greeting.hello',
        'startedAt': now.toIso8601String(),
      });
      await until(() => process.log.activeOperations.isNotEmpty);

      final early = process.serverStatus(now: now);
      expect(early.kind, ServerStatusKind.running);

      final later = process.serverStatus(
        now: now.add(kStatusOperationDelay),
      );
      expect(later.kind, ServerStatusKind.busy);
      expect(later.message, 'greeting.hello');
    });

    test('a failed build is stopped, with the reason in the detail', () async {
      final runner = await projectWithRunner(stage: 'degraded');
      await open(runner);

      final status = process.serverStatus();
      expect(status.kind, ServerStatusKind.stopped);
      expect(status.message, 'Build failed');
      expect(status.detail, contains('failed to build'));
    });
  });
}
