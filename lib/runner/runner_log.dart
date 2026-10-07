import 'package:flutter/foundation.dart';

import 'runner_protocol.dart';

/// A companion Flutter app: what the runner was told about it, where it is,
/// and what it has printed.
class FlutterAppLog {
  FlutterAppLog(this.config);

  FlutterAppConfig config;
  FlutterAppStatus status = FlutterAppStatus.stopped;
  final List<String> lines = [];

  String get id => config.id;
  String get name => config.name;
}

/// App Studio's mirror of a runner's log history, kept current from the
/// snapshot and the events that follow it. This is what the log pane draws.
///
/// Built the way the CLI's own `StartLogHistory` is applied on a client, so
/// the two cannot disagree about what a sequence of events means: a snapshot
/// *replaces* the runner's history (a reconnect may reach a different runner),
/// and an event appends to it.
///
/// App Studio writes here too ([addLocal]) — `pub get` and starting the runner
/// happen before there is a runner to report them. Those records sit in front
/// of the runner's and survive a snapshot; [clear] is the only thing that
/// drops them.
///
/// Bounded: the runner caps its own history, but a client attached for a day
/// would otherwise keep every event since.
class RunnerLog extends ChangeNotifier {
  RunnerLog({this.maxItems = 5000, this.maxLinesPerApp = 5000});

  final int maxItems;
  final int maxLinesPerApp;

  final List<RunnerLogRecord> _local = [];
  final List<ServerLogItem> _runnerItems = [];
  final Map<String, ActiveOperation> _active = {};
  final Map<String, FlutterAppLog> _apps = {};

  /// Bumped on every change, so a view can tell whether to rebuild its
  /// filtered list without comparing the lists themselves.
  int get revision => _revision;
  int _revision = 0;

  /// App Studio's records and the runner's, merged by time, oldest first.
  ///
  /// Each list is already in order, so this is a merge, not a sort; on a tie
  /// the runner's item goes first. Cached per [revision] — the log pane asks
  /// on every rebuild.
  List<ServerLogItem> get serverItems {
    if (_mergedRevision == _revision) return _merged;
    final merged = <ServerLogItem>[];
    var local = 0;
    var runner = 0;
    while (local < _local.length || runner < _runnerItems.length) {
      final takeLocal = runner >= _runnerItems.length ||
          (local < _local.length &&
              _local[local].time.isBefore(_runnerItems[runner].time));
      merged.add(takeLocal ? _local[local++] : _runnerItems[runner++]);
    }
    _mergedRevision = _revision;
    return _merged = List.unmodifiable(merged);
  }

  List<ServerLogItem> _merged = const [];
  int _mergedRevision = -1;

  /// Operations in flight, oldest first.
  List<ActiveOperation> get activeOperations => _active.values.toList()
    ..sort((a, b) => a.startedAt.compareTo(b.startedAt));

  /// The configured Flutter apps, in the runner's order.
  List<FlutterAppLog> get apps => _apps.values.toList(growable: false);

  FlutterAppLog? app(String id) => _apps[id];

  /// Appends a record App Studio wrote itself, stamped [time] or now.
  void addLocal(
    String message, {
    RunnerLogLevel level = RunnerLogLevel.info,
    String? error,
    DateTime? time,
  }) {
    _local.add(
      RunnerLogRecord(
        time: time ?? DateTime.now(),
        level: level,
        message: message,
        error: error,
        source: RunnerLogSource.appStudio,
      ),
    );
    _trim(_local, maxItems);
    _changed();
  }

  /// Drops everything — a new project, or a fresh start of the same one.
  void clear() {
    _local.clear();
    _clearRunner();
    _changed();
  }

  /// Forgets the runner's state but keeps App Studio's records: the runner is
  /// gone, and whatever it said is still worth reading.
  void detach() {
    _active.clear();
    for (final app in _apps.values) {
      app.status = FlutterAppStatus.stopped;
    }
    _changed();
  }

  void applySnapshot(RunnerSnapshot snapshot) {
    _clearRunner();
    _runnerItems.addAll(snapshot.serverItems);
    _trim(_runnerItems, maxItems);
    for (final operation in snapshot.activeOperations) {
      _active[operation.id] = operation;
    }
    _setApps(snapshot.flutterApps);
    for (final app in _apps.values) {
      app.lines.addAll(snapshot.flutterLines[app.id] ?? const []);
      _trim(app.lines, maxLinesPerApp);
      app.status = FlutterAppStatus(
        running: snapshot.runningFlutterApps.contains(app.id),
        launching: snapshot.launchingFlutterApps.contains(app.id),
        url: snapshot.flutterAppUrls[app.id],
      );
    }
    _changed();
  }

  void applyEvent(RunnerEvent event) {
    switch (event) {
      case ServerLogEvent(:final record):
        _addRunnerItem(record);
      case OperationStartedEvent(:final operation):
        _active[operation.id] = operation;
      case OperationCompletedEvent(:final id, :final operation):
        _active.remove(id);
        _addRunnerItem(operation);
      case OperationsDiscardedEvent(:final ids):
        ids.forEach(_active.remove);
      case FlutterLineEvent(:final appId, :final lines):
        final app = _apps[appId] ??=
            FlutterAppLog(FlutterAppConfig(id: appId, name: appId));
        app.lines.addAll(lines);
        _trim(app.lines, maxLinesPerApp);
      case FlutterAppsChangedEvent(:final apps):
        _setApps(apps);
      case FlutterAppStateEvent(:final appId, :final status):
        final app = _apps[appId];
        if (app == null) return;
        // A running app's progress update carries no URL, so keep the last —
        // the same rule the CLI's own client applies.
        app.status = FlutterAppStatus(
          running: status.running,
          launching: status.launching,
          launchStage: status.launchStage,
          url: status.url ?? (status.running ? app.status.url : null),
        );
      case StageChangedEvent():
        return;
    }
    _changed();
  }

  void _addRunnerItem(ServerLogItem item) {
    _runnerItems.add(item);
    _trim(_runnerItems, maxItems);
  }

  /// Replaces the app list, keeping each surviving app's lines and status.
  void _setApps(List<FlutterAppConfig> configs) {
    final previous = Map.of(_apps);
    _apps.clear();
    for (final config in configs) {
      _apps[config.id] = (previous[config.id] ?? FlutterAppLog(config))
        ..config = config;
    }
  }

  void _clearRunner() {
    _runnerItems.clear();
    _active.clear();
    _apps.clear();
  }

  void _changed() {
    _revision++;
    notifyListeners();
  }

  static void _trim<T>(List<T> list, int max) {
    if (list.length > max) list.removeRange(0, list.length - max);
  }
}
