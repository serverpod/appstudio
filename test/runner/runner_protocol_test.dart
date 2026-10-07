import 'package:appstudio/runner/runner_log.dart';
import 'package:appstudio/runner/runner_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

/// Payloads as `serverpod_cli` 4.1.0-beta.1 sends them, captured from a live
/// runner.
void main() {
  group('decoding', () {
    test('a log event, with the root scope dropped', () {
      final event = RunnerEvent.fromJson({
        'event': 'log',
        'type': 'log',
        'time': '2026-10-07T18:21:32.299137Z',
        'level': 'info',
        'message': 'The Dart VM service is listening',
        'scope': {'id': 'root', 'label': 'unknown'},
        'metadata': {'serverpod:logType': "Instance of 'TextLogType'"},
      });

      final record = (event! as ServerLogEvent).record;
      expect(record.message, 'The Dart VM service is listening');
      expect(record.level, RunnerLogLevel.info);
      expect(record.scope, isNull);
      expect(record.time.isUtc, isTrue);
    });

    test('a named scope is kept, and error details decode', () {
      final record = RunnerLogRecord.fromJson({
        'type': 'log',
        'time': '2026-10-07T18:21:32Z',
        'level': 'error',
        'message': 'Failed',
        'scope': {'id': '91106_6', 'label': 'greeting.hello'},
        'error': 'Bad state',
        'stackTrace': '#0 main',
      });

      expect(record.scope, 'greeting.hello');
      expect(record.hasDetails, isTrue);
      expect(record.level.isAtLeast(RunnerLogLevel.warning), isTrue);
    });

    test('an operation, whose time carries no zone', () {
      final event = RunnerEvent.fromJson({
        'type': 'operation',
        'label': 'Hot restart',
        'success': true,
        'durationMs': 1020,
        'completedAt': '2026-10-07T20:22:55.871064',
        'event': 'operationCompleted',
        'operationId': 'runner_1',
      });

      final completed = event! as OperationCompletedEvent;
      expect(completed.id, 'runner_1');
      expect(completed.operation.duration, const Duration(milliseconds: 1020));
      expect(completed.operation.completedAt.isUtc, isFalse);
    });

    test('a Flutter app state, with and without a URL', () {
      final running = RunnerEvent.fromJson({
        'event': 'flutterAppState',
        'appId': 'probe_app',
        'running': true,
        'launching': false,
        'url': 'http://localhost:49301',
      })! as FlutterAppStateEvent;
      expect(running.status.url, 'http://localhost:49301');

      final progress = RunnerEvent.fromJson({
        'event': 'flutterAppState',
        'appId': 'probe_app',
        'running': true,
        'launching': false,
        'launchStage': 'Performing hot restart...',
      })! as FlutterAppStateEvent;
      expect(progress.status.url, isNull);
      expect(progress.status.launchStage, 'Performing hot restart...');
    });

    test('a Flutter entry the runner appended to the lines arrives as lines',
        () {
      final event = RunnerEvent.fromJson({
        'event': 'flutterLog',
        'appId': 'demo',
        'appendedToLines': true,
        'type': 'log',
        'time': '2026-10-07T18:22:01Z',
        'level': 'error',
        'message': '══ Exception caught by widgets ══',
        'error': 'RenderFlex overflowed',
      })! as FlutterLineEvent;

      expect(event.lines, [
        '══ Exception caught by widgets ══',
        'RenderFlex overflowed',
      ]);
    });

    test('raw output, a structured copy of printed lines, and unknown '
        'events are skipped', () {
      expect(RunnerEvent.fromJson({'event': 'serverLine', 'line': 'x'}), isNull);
      expect(
        RunnerEvent.fromJson({
          'event': 'flutterLog',
          'appId': 'demo',
          'type': 'log',
          'message': 'printed already',
        }),
        isNull,
      );
      expect(RunnerEvent.fromJson({'event': 'fromTheFuture'}), isNull);
    });

    test('a snapshot', () {
      final snapshot = RunnerSnapshot.fromJson({
        'stage': 'running',
        'isRunning': true,
        'canLaunchFlutterApps': true,
        'serverLines': ['ignored'],
        'serverEntries': [
          {
            'type': 'operation',
            'label': 'Compiling server',
            'success': true,
            'durationMs': 4862,
            'completedAt': '2026-10-07T20:21:31.884122',
          },
          {'type': 'somethingNew'},
        ],
        'activeOperations': [
          {'id': 'op', 'label': 'Launching', 'startedAt': '2026-10-07T20:21:50'},
        ],
        'flutterApps': [
          {'id': 'probe_app', 'name': 'Probe app', 'autoLaunch': true},
        ],
        'flutterLines': {
          'probe_app': ['one', 'two'],
        },
        'runningFlutterApps': ['probe_app'],
        'launchingFlutterApps': <Object?>[],
        'flutterAppUrls': {'probe_app': 'http://localhost:49301'},
      });

      expect(snapshot.stage, RunnerStage.running);
      expect(snapshot.serverItems, hasLength(1));
      expect(snapshot.activeOperations.single.label, 'Launching');
      expect(snapshot.flutterApps.single.name, 'Probe app');
      expect(snapshot.flutterLines['probe_app'], ['one', 'two']);
      expect(snapshot.flutterAppUrls['probe_app'], 'http://localhost:49301');
    });

    test('ANSI escapes are stripped', () {
      expect(stripAnsi('\x1B[32mgreen\x1B[0m'), 'green');
    });
  });

  group('RunnerLog', () {
    RunnerSnapshot snapshot({List<String> lines = const []}) => RunnerSnapshot(
          stage: RunnerStage.running,
          flutterApps: const [FlutterAppConfig(id: 'a', name: 'App')],
          flutterLines: {'a': lines},
          serverItems: [
            RunnerLogRecord(
              time: DateTime.utc(2026, 1, 1, 12),
              level: RunnerLogLevel.info,
              message: 'from the runner',
            ),
          ],
        );

    test('a snapshot replaces the runner’s history but keeps App Studio’s',
        () {
      final log = RunnerLog()
        ..addLocal('pub get', time: DateTime.utc(2026, 1, 1, 11))
        ..applySnapshot(snapshot(lines: ['first']))
        ..applySnapshot(snapshot(lines: ['second']));

      expect(
        log.serverItems.whereType<RunnerLogRecord>().map((r) => r.message),
        ['pub get', 'from the runner'],
      );
      expect(log.app('a')!.lines, ['second']);
    });

    test('records merge by time', () {
      final log = RunnerLog()
        ..applySnapshot(snapshot())
        ..addLocal('later', time: DateTime.utc(2026, 1, 1, 13))
        ..addLocal('earlier', time: DateTime.utc(2026, 1, 1, 10));

      // App Studio's own records keep their order among themselves.
      expect(
        log.serverItems.whereType<RunnerLogRecord>().map((r) => r.message),
        ['from the runner', 'later', 'earlier'],
      );
    });

    test('an operation leaves the active list when it completes', () {
      final log = RunnerLog()
        ..applySnapshot(snapshot())
        ..applyEvent(
          OperationStartedEvent(
            ActiveOperation(id: '1', label: 'Hot restart', startedAt: DateTime.now()),
          ),
        );
      expect(log.activeOperations.single.label, 'Hot restart');

      log.applyEvent(
        OperationCompletedEvent(
          id: '1',
          operation: RunnerOperation(
            label: 'Hot restart',
            success: true,
            duration: const Duration(seconds: 1),
            completedAt: DateTime.now(),
          ),
        ),
      );
      expect(log.activeOperations, isEmpty);
      expect(log.serverItems.last, isA<RunnerOperation>());
    });

    test('is bounded', () {
      final log = RunnerLog(maxItems: 3);
      for (var i = 0; i < 10; i++) {
        log.applyEvent(
          ServerLogEvent(
            RunnerLogRecord(
              time: DateTime.utc(2026, 1, 1, 12, 0, i),
              level: RunnerLogLevel.info,
              message: '$i',
            ),
          ),
        );
      }
      expect(
        log.serverItems.whereType<RunnerLogRecord>().map((r) => r.message),
        ['7', '8', '9'],
      );
    });

    test('detach stops the apps but keeps what was said', () {
      final log = RunnerLog()
        ..applySnapshot(snapshot(lines: ['kept']))
        ..applyEvent(
          const FlutterAppStateEvent(
            appId: 'a',
            status: FlutterAppStatus(running: true, url: 'http://x'),
          ),
        )
        ..detach();

      expect(log.app('a')!.status.url, isNull);
      expect(log.app('a')!.lines, ['kept']);
      expect(log.serverItems, isNotEmpty);
    });
  });
}
