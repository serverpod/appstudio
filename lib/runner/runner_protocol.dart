/// The runner's attach protocol, as App Studio reads it.
///
/// `serverpod runner serve` (Serverpod 4.1) is the long-lived development
/// stack — server, generator, watcher and Flutter apps — and serves this
/// protocol on `.dart_tool/serverpod/tui.sock`: newline-delimited JSON-RPC 2.0.
/// A client asks for a `snapshot`, then receives every later change as an
/// `event` notification. The CLI's own TUI is just another client of it.
///
/// Mirrors `serverpod_cli`'s `runner_snapshot.dart`, `runner_event.dart` and
/// `log_codec.dart` (protocol version [kRunnerProtocolVersion]). Decoding is
/// deliberately forgiving: a missing field costs that field, and an event kind
/// only a newer runner knows decodes to null and is skipped — the same rules
/// the CLI applies to itself.
///
/// Pure Dart, no `dart:io`, so it can be fed by Widgetbook and tests.
library;

/// The attach protocol version this client speaks. A runner publishing another
/// one in its manifest is refused, as the CLI refuses it.
const kRunnerProtocolVersion = 1;

/// How far the runner has got.
enum RunnerStage {
  /// Provisioning: Docker, code generation, the first compile.
  starting,

  /// The server is up.
  running,

  /// The project failed to build. The watcher or `retryStart` recovers it.
  degraded,

  /// Shutting down.
  stopping;

  static RunnerStage byName(Object? name) => values.firstWhere(
        (stage) => stage.name == name,
        orElse: () => RunnerStage.starting,
      );
}

/// Severity of a [RunnerLogRecord], ordered so a filter can compare them.
enum RunnerLogLevel {
  debug,
  info,
  warning,
  error,
  fatal;

  static RunnerLogLevel byName(Object? name) => switch (name) {
        'debug' => debug,
        'warning' || 'warn' => warning,
        'error' => error,
        'fatal' => fatal,
        _ => info,
      };

  bool isAtLeast(RunnerLogLevel other) => index >= other.index;
}

/// Who wrote a [RunnerLogRecord].
enum RunnerLogSource {
  /// The runner or the pod, through the attach protocol.
  runner,

  /// App Studio itself — `pub get` before the runner exists, and what it did.
  appStudio,
}

/// One entry in the server log: a [RunnerLogRecord] or a finished
/// [RunnerOperation].
sealed class ServerLogItem {
  const ServerLogItem();

  DateTime get time;
}

/// A structured log entry from the runner, the pod, or App Studio.
final class RunnerLogRecord extends ServerLogItem {
  const RunnerLogRecord({
    required this.time,
    required this.level,
    required this.message,
    this.scope,
    this.error,
    this.stackTrace,
    this.source = RunnerLogSource.runner,
  });

  @override
  final DateTime time;
  final RunnerLogLevel level;
  final String message;

  /// The pod's log scope, such as an endpoint call. Null for the root scope,
  /// which the runner labels `unknown` and carries no information.
  final String? scope;

  final String? error;
  final String? stackTrace;
  final RunnerLogSource source;

  /// Whether there is more than the message to show.
  bool get hasDetails =>
      (error?.isNotEmpty ?? false) || (stackTrace?.isNotEmpty ?? false);

  static RunnerLogRecord fromJson(Map<String, Object?> json) {
    final scope = json['scope'];
    final label = scope is Map ? scope['label'] : null;
    final scopeId = scope is Map ? scope['id'] : json['scopeId'];
    final stackTrace = json['stackTrace'];
    final error = json['error'];
    return RunnerLogRecord(
      time: parseRunnerTime(json['time'] ?? json['timestamp']),
      level: RunnerLogLevel.byName(json['level']),
      message: _string(json['message']),
      scope: scopeId == 'root' || label is! String || label.isEmpty
          ? null
          : label,
      error: error == null ? null : '$error',
      stackTrace:
          stackTrace is String && stackTrace.isNotEmpty ? stackTrace : null,
    );
  }
}

/// A finished operation — a compile, a server scope, a Flutter launch — with
/// the duration the runner measured.
final class RunnerOperation extends ServerLogItem {
  const RunnerOperation({
    required this.label,
    required this.success,
    required this.duration,
    required this.completedAt,
  });

  final String label;
  final bool success;
  final Duration duration;
  final DateTime completedAt;

  @override
  DateTime get time => completedAt;

  static RunnerOperation fromJson(Map<String, Object?> json) => RunnerOperation(
        label: _string(json['label']),
        success: json['success'] as bool? ?? true,
        duration: Duration(milliseconds: _int(json['durationMs']) ?? 0),
        completedAt: parseRunnerTime(json['completedAt']),
      );
}

/// An operation still in flight.
final class ActiveOperation {
  const ActiveOperation({
    required this.id,
    required this.label,
    required this.startedAt,
  });

  final String id;
  final String label;
  final DateTime startedAt;

  static ActiveOperation fromJson(Map<String, Object?> json) => ActiveOperation(
        id: _string(json['id']),
        label: _string(json['label']),
        startedAt: parseRunnerTime(json['startedAt']),
      );
}

/// Flutter's headless web device: it serves the app and opens nothing, so the
/// preview pane is the only page that ever loads it. Without a `device`, the
/// runner launches on `web-server-launch-browser`, which also opens the system
/// browser.
const kHeadlessWebDevice = 'web-server';

/// A companion Flutter app the runner knows about, as configured under
/// `serverpod: flutter_apps:` in the server's pubspec.
final class FlutterAppConfig {
  const FlutterAppConfig({
    required this.id,
    required this.name,
    this.autoLaunch = false,
    this.device,
  });

  final String id;

  /// The display name, or [id] when none is configured.
  final String name;

  final bool autoLaunch;

  /// The `flutter run -d` target, or null for the runner's default — which is
  /// `web-server-launch-browser` and opens the system browser.
  final String? device;

  static FlutterAppConfig fromJson(Map<String, Object?> json) {
    final id = _string(json['id']);
    final name = _string(json['name']);
    return FlutterAppConfig(
      id: id,
      name: name.isEmpty ? id : name,
      autoLaunch: json['autoLaunch'] as bool? ?? false,
      device: json['device'] as String?,
    );
  }
}

/// Where a Flutter app is in its life, as the runner last reported it.
final class FlutterAppStatus {
  const FlutterAppStatus({
    this.running = false,
    this.launching = false,
    this.url,
    this.launchStage,
  });

  static const stopped = FlutterAppStatus();

  final bool running;

  /// Between the spawn and the ready signal.
  final bool launching;

  /// The app's URL, null on non-web devices and until the web server is up.
  final String? url;

  /// The toolchain step of a launching app, such as compiling, or null.
  final String? launchStage;
}

/// The runner's state when a client attaches.
final class RunnerSnapshot {
  const RunnerSnapshot({
    required this.stage,
    this.exitCode,
    this.canLaunchFlutterApps = false,
    this.serverItems = const [],
    this.activeOperations = const [],
    this.flutterApps = const [],
    this.flutterLines = const {},
    this.runningFlutterApps = const {},
    this.launchingFlutterApps = const {},
    this.flutterAppUrls = const {},
  });

  final RunnerStage stage;

  /// The exit code once stopping, carried here since events do not replay.
  final int? exitCode;

  final bool canLaunchFlutterApps;
  final List<ServerLogItem> serverItems;
  final List<ActiveOperation> activeOperations;
  final List<FlutterAppConfig> flutterApps;
  final Map<String, List<String>> flutterLines;
  final Set<String> runningFlutterApps;
  final Set<String> launchingFlutterApps;
  final Map<String, String?> flutterAppUrls;

  /// Raw pod output (`serverLines`) is deliberately not read: App Studio shows
  /// the structured log only, which carries the pod's own entries too.
  static RunnerSnapshot fromJson(Map<String, Object?> json) => RunnerSnapshot(
        stage: RunnerStage.byName(json['stage']),
        exitCode: _int(json['exitCode']),
        canLaunchFlutterApps: json['canLaunchFlutterApps'] as bool? ?? false,
        serverItems: [
          for (final item in _maps(json['serverEntries']))
            ?decodeServerLogItem(item),
        ],
        activeOperations: [
          for (final item in _maps(json['activeOperations']))
            ActiveOperation.fromJson(item),
        ],
        flutterApps: [
          for (final item in _maps(json['flutterApps']))
            FlutterAppConfig.fromJson(item),
        ],
        flutterLines: switch (json['flutterLines']) {
          final Map<Object?, Object?> map => {
              for (final MapEntry(:key, :value) in map.entries)
                '$key': [for (final line in _list(value)) '$line'],
            },
          _ => const {},
        },
        runningFlutterApps: {
          for (final id in _list(json['runningFlutterApps'])) '$id',
        },
        launchingFlutterApps: {
          for (final id in _list(json['launchingFlutterApps'])) '$id',
        },
        flutterAppUrls: switch (json['flutterAppUrls']) {
          final Map<Object?, Object?> map => {
              for (final MapEntry(:key, :value) in map.entries)
                '$key': value is String ? value : null,
            },
          _ => const {},
        },
      );
}

/// Decodes a server history item, or null for a type only a newer runner
/// knows.
ServerLogItem? decodeServerLogItem(Map<String, Object?> json) =>
    switch (json['type']) {
      'log' => RunnerLogRecord.fromJson(json),
      'operation' => RunnerOperation.fromJson(json),
      _ => null,
    };

/// Everything after the snapshot.
sealed class RunnerEvent {
  const RunnerEvent();

  /// Decodes an event, or null for a kind this client does not use.
  ///
  /// `serverLine` (raw pod output) and `manifest` are dropped here on purpose:
  /// the log is the structured one, and the manifest is re-read from disk when
  /// it is needed.
  static RunnerEvent? fromJson(Map<String, Object?> json) =>
      switch (json['event']) {
        'log' => ServerLogEvent(RunnerLogRecord.fromJson(json)),
        'operationStarted' =>
          OperationStartedEvent(ActiveOperation.fromJson(json)),
        'operationCompleted' => OperationCompletedEvent(
            id: _string(json['operationId']),
            operation: RunnerOperation.fromJson(json),
          ),
        'operationsDiscarded' => OperationsDiscardedEvent([
            for (final id in _list(json['operationIds'])) '$id',
          ]),
        'flutterLine' => FlutterLineEvent(
            appId: _string(json['appId']),
            line: _string(json['line']),
          ),
        'flutterLog' when json['appendedToLines'] == true =>
          FlutterLineEvent.fromEntry(
            appId: _string(json['appId']),
            entry: RunnerLogRecord.fromJson(json),
          ),
        'stage' => StageChangedEvent(
            RunnerStage.byName(json['stage']),
            exitCode: _int(json['exitCode']),
          ),
        'flutterApps' => FlutterAppsChangedEvent([
            for (final app in _maps(json['apps'])) FlutterAppConfig.fromJson(app),
          ]),
        'flutterAppState' => FlutterAppStateEvent(
            appId: _string(json['appId']),
            status: FlutterAppStatus(
              running: json['running'] as bool? ?? false,
              launching: json['launching'] as bool? ?? false,
              url: json['url'] as String?,
              launchStage: json['launchStage'] as String?,
            ),
          ),
        _ => null,
      };
}

final class ServerLogEvent extends RunnerEvent {
  const ServerLogEvent(this.record);

  final RunnerLogRecord record;
}

final class OperationStartedEvent extends RunnerEvent {
  const OperationStartedEvent(this.operation);

  final ActiveOperation operation;
}

final class OperationCompletedEvent extends RunnerEvent {
  const OperationCompletedEvent({required this.id, required this.operation});

  /// The [OperationStartedEvent] id, since labels are not unique.
  final String id;
  final RunnerOperation operation;
}

/// Operations that will never complete, such as a dead pod's open scopes.
final class OperationsDiscardedEvent extends RunnerEvent {
  const OperationsDiscardedEvent(this.ids);

  final List<String> ids;
}

/// Raw output lines from a Flutter app.
///
/// One `flutterLine` is one line. A `flutterLog` entry flagged
/// `appendedToLines` — a VM service event such as `Flutter.Error`, which never
/// printed — is appended to the app's lines by the runner, so a mirror must
/// append it too; it arrives here already split.
final class FlutterLineEvent extends RunnerEvent {
  FlutterLineEvent({required this.appId, required String line})
      : lines = [line];

  FlutterLineEvent.fromEntry({
    required this.appId,
    required RunnerLogRecord entry,
  }) : lines = _entryLines(entry);

  final String appId;
  final List<String> lines;
}

final class StageChangedEvent extends RunnerEvent {
  const StageChangedEvent(this.stage, {this.exitCode});

  final RunnerStage stage;

  /// The exit code on [RunnerStage.stopping]. Null reads as clean.
  final int? exitCode;
}

final class FlutterAppsChangedEvent extends RunnerEvent {
  const FlutterAppsChangedEvent(this.apps);

  final List<FlutterAppConfig> apps;
}

final class FlutterAppStateEvent extends RunnerEvent {
  const FlutterAppStateEvent({required this.appId, required this.status});

  final String appId;
  final FlutterAppStatus status;
}

/// The outcome of one of the runner's migration commands.
final class MigrationResult {
  const MigrationResult({
    required this.message,
    this.isError = false,
    this.abortedForWarnings = false,
    this.created = false,
  });

  /// What happened, in the runner's words. Carries no retry hint.
  final String message;

  final bool isError;

  /// The command stopped at warnings that `force: true` overrides.
  final bool abortedForWarnings;

  /// A server migration was written to disk.
  final bool created;

  static MigrationResult fromJson(Map<String, Object?> json) => MigrationResult(
        message: _string(json['message']),
        isError: json['isError'] as bool? ?? false,
        abortedForWarnings: json['abortedForWarnings'] as bool? ?? false,
        created: json['created'] as bool? ?? false,
      );
}

/// A timestamp from the runner. Log entries carry UTC with a `Z`; operation
/// times are local without one — `DateTime.parse` reads each correctly.
DateTime parseRunnerTime(Object? value) =>
    DateTime.tryParse(value is String ? value : '') ?? DateTime.now();

final _ansi = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');

/// [text] without ANSI escape sequences.
String stripAnsi(String text) => text.replaceAll(_ansi, '');

/// An entry's message, error and stack trace as lines, the way the runner
/// appends them to a Flutter app's output.
List<String> _entryLines(RunnerLogRecord entry) {
  final raw = StringBuffer(entry.message);
  if (entry.error != null) {
    if (raw.isNotEmpty) raw.writeln();
    raw.write(entry.error);
  }
  if (entry.stackTrace != null) {
    if (raw.isNotEmpty) raw.writeln();
    raw.write(entry.stackTrace);
  }
  return stripAnsi(raw.toString()).split('\n');
}

String _string(Object? value) => value is String ? value : '';

int? _int(Object? value) => value is num ? value.toInt() : null;

List<Object?> _list(Object? value) => value is List ? value : const [];

List<Map<String, Object?>> _maps(Object? value) => [
      for (final entry in _list(value))
        if (entry is Map) Map<String, Object?>.from(entry),
    ];
