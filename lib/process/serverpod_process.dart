import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../preview/preview_phase.dart';
import '../process/full_restart_view.dart';
import '../process/project_ready_view.dart';
import '../process/registration_code.dart';
import '../runner/runner_actions_view.dart';
import '../runner/runner_client.dart';
import '../runner/runner_discovery.dart';
import '../runner/runner_log.dart';
import '../runner/runner_ownership.dart';
import '../runner/runner_protocol.dart';
import '../session/project_session.dart';
import '../toolchain/tool_status.dart';
import '../toolchain/toolchain.dart';
import '../toolchain/toolchain_controller.dart';
import 'project_dependencies.dart';

enum ProcessState { idle, starting, running, stopping }

/// A `serverpod runner start` in flight: its output, and how it ended.
class RunnerLaunch {
  RunnerLaunch({
    required this.output,
    required this.exitCode,
    required this.kill,
  });

  final Stream<String> output;
  final Future<int> exitCode;
  final void Function() kill;
}

/// Brings a runner up for [serverDir] with [toolchain]'s Serverpod CLI.
/// Injectable so tests can stand a fake runner up in-process instead.
typedef RunnerLauncher = Future<RunnerLaunch> Function({
  required Toolchain toolchain,
  required String serverDir,
});

/// Resolves the project's packages before a runner is started for it.
typedef DependencyResolver = Future<void> Function(
  String projectPath,
  RunnerLog log,
  bool Function() isCancelled,
);

/// `(pid 12345)`, as `serverpod runner start` names the runner it spawned.
final _runnerPid = RegExp(r'\(pid (\d+)\)');

/// Owns the project's Serverpod runner: starts or finds it, attaches to it,
/// mirrors its log, and sends it commands.
///
/// Serverpod 4.1 split `serverpod start` in two: a detached runner
/// (`serverpod runner serve`) that *is* the development stack, and clients
/// that attach to its socket — the CLI's TUI is one, and App Studio is
/// another. So there is no output to scrape any more: stages, log entries,
/// operations and the Flutter app's URL all arrive as structured events
/// (`lib/runner/`), and hot reload, hot restart and migrations are commands on
/// the same connection.
///
/// **A runner may not be ours.** One runner serves each server package, and a
/// terminal `serverpod start` or an AI agent may have brought it up first.
/// Opening such a project attaches to it, and closing it only detaches; a
/// runner App Studio started is stopped when the project closes or the app
/// quits. Ownership is recorded on disk ([recordOwnedRunner]) so a crash or a
/// hot restart of App Studio cannot strand one.
class ServerpodProcessController extends ChangeNotifier
    implements FullRestartView, ProjectReadyView, RunnerActionsView {
  ServerpodProcessController({
    required this.toolchains,
    required this.session,
    RunnerLog? log,
    RunnerLauncher? launcher,
    DependencyResolver? dependencies,
  })  : log = log ?? RunnerLog(),
        _launcher = launcher ?? launchRunnerProcess,
        _resolveDependencies = dependencies {
    session.addListener(_onSessionChanged);
    _onSessionChanged();
  }

  final ToolchainController toolchains;
  final ProjectSession session;

  /// What the server log pane draws.
  final RunnerLog log;

  final RunnerLauncher _launcher;
  final DependencyResolver? _resolveDependencies;

  String? _boundProjectPath;

  /// Bumped by every project switch, so only the latest one starts a runner.
  int _switches = 0;

  /// Bumped by every start and stop, so a start overtaken by either drops out
  /// at its next await instead of attaching a runner nobody wants.
  int _epoch = 0;

  bool _starting = false;
  bool _preparing = false;
  bool _stopping = false;
  bool _restarting = false;
  Completer<void>? _stopDone;
  String? _error;

  String? _serverDir;
  RunnerLaunch? _launch;
  RunnerClient? _client;
  StreamSubscription<RunnerEvent>? _eventSub;
  RunnerStage? _stage;
  int? _exitCode;
  bool _canLaunchFlutterApps = false;
  bool _owned = false;
  int? _pid;

  String? _previewUrl;
  bool _live = false;
  bool _launchRequested = false;
  int _previewReloadToken = 0;
  String? _registrationCode;

  RunnerAction? _runningAction;
  RunnerAction? _failedAction;
  String? _actionError;

  /// The runner's stage, or null with no runner attached.
  RunnerStage? get stage => _stage;

  /// Whether the attached runner is one App Studio started, and so stops.
  bool get ownsRunner => _owned;

  ProcessState get state {
    if (_stopping) return ProcessState.stopping;
    if (_client != null) {
      return switch (_stage) {
        RunnerStage.running || RunnerStage.degraded => ProcessState.running,
        RunnerStage.stopping => ProcessState.stopping,
        RunnerStage.starting || null => ProcessState.starting,
      };
    }
    return _starting ? ProcessState.starting : ProcessState.idle;
  }

  PreviewPhase get phase {
    switch (state) {
      case ProcessState.idle:
        return _error != null ? PreviewPhase.failed : PreviewPhase.idle;
      case ProcessState.stopping:
        return PreviewPhase.stopping;
      case ProcessState.starting || ProcessState.running:
        break;
    }
    if (_error != null || _stage == RunnerStage.degraded) {
      return PreviewPhase.failed;
    }
    if (_preparing) return PreviewPhase.fetchingDependencies;
    if (_client == null) return PreviewPhase.startingServerpod;
    if (_previewUrl != null) {
      return _live ? PreviewPhase.ready : PreviewPhase.connecting;
    }
    final app = previewApp;
    if ((app?.status.launching ?? false) || _stage == RunnerStage.running) {
      return PreviewPhase.loadingApp;
    }
    return PreviewPhase.waitingForServer;
  }

  /// The Flutter app the preview shows: the one with a URL, else the one
  /// configured for the headless web device, else the first.
  FlutterAppLog? get previewApp {
    final apps = log.apps;
    return apps.where((app) => app.status.url != null).firstOrNull ??
        apps.where((a) => a.config.device == kHeadlessWebDevice).firstOrNull ??
        apps.firstOrNull;
  }

  /// Where the preview loads the app. The runner publishes it — `flutter run
  /// -d web-server` picks a free port, so it differs per project and per run.
  Uri? get previewUrl => switch (_previewUrl) {
        final url? => Uri.tryParse(url),
        null => null,
      };

  /// The Flutter app is being served, so CEF may load it.
  bool get previewReady =>
      _previewUrl != null &&
      (state == ProcessState.starting || state == ProcessState.running);

  /// The whole stack is up and the app is live in the preview.
  ///
  /// Stricter than [previewReady]: with `-d web-server` the app's `main()`
  /// only runs once a page has connected, and the page reports that itself.
  /// `PreviewPhase.ready` is the first moment there is a running project to
  /// hand to an editor.
  @override
  bool get projectIsReady => phase == PreviewPhase.ready;

  /// Increments when the preview should hard-reload.
  int get previewReloadToken => _previewReloadToken;

  /// Why the server is not running, if that is a failure.
  String? get error =>
      _error ??
      (_stage == RunnerStage.degraded
          ? 'The project failed to build, so the server is not running. The '
              'server log has the errors — it starts again as soon as the '
              'project builds.'
          : null);

  /// Sign-up code the server last logged, until dismissed or superseded.
  String? get registrationCode => _registrationCode;

  bool get canStop =>
      state == ProcessState.running || state == ProcessState.starting;

  /// True for the whole of [restart], across the stop *and* the start.
  ///
  /// Without it the UI sees a moment of [ProcessState.idle] between the two and
  /// flips the restart button to "start the server", which reads as the restart
  /// having failed.
  bool get isRestarting => _restarting;

  @override
  bool get isTransitioning =>
      _restarting ||
      state == ProcessState.starting ||
      state == ProcessState.stopping;

  @override
  bool get canRestart => session.hasProject && !isTransitioning;

  @override
  bool get isStopped => state == ProcessState.idle;

  @override
  bool get canHotReload =>
      _client != null && _stage == RunnerStage.running && !_stopping;

  @override
  bool get canMigrate =>
      _client != null &&
      (_stage == RunnerStage.running || _stage == RunnerStage.degraded) &&
      !_stopping;

  @override
  RunnerAction? get runningAction => _runningAction;

  @override
  RunnerAction? get failedAction => _failedAction;

  @override
  String? get actionError => _actionError;

  void _onSessionChanged() {
    final path = session.projectPath;
    if (path == null) {
      _boundProjectPath = null;
      unawaited(stop());
      return;
    }
    if (path == _boundProjectPath && state != ProcessState.idle) return;
    unawaited(_startForProject(path));
  }

  Future<void> _startForProject(String projectPath) async {
    final ticket = ++_switches;
    if (state != ProcessState.idle || _launch != null) await stop();
    if (ticket != _switches || session.projectPath != projectPath) return;
    _boundProjectPath = projectPath;
    await start();
  }

  /// Finds the project's runner and attaches to it, starting one first if
  /// none is running.
  Future<void> start() async {
    final projectPath = session.projectPath;
    if (projectPath == null || _starting || _client != null || _stopping) {
      return;
    }
    final epoch = ++_epoch;
    bool cancelled() => epoch != _epoch || session.projectPath != projectPath;

    _starting = true;
    _error = null;
    _registrationCode = null;
    _launchRequested = false;
    _live = false;
    _previewUrl = null;
    _owned = false;
    _pid = null;
    log.clear();
    notifyListeners();

    try {
      final serverDir = await findServerDirectory(projectPath);
      if (serverDir == null) {
        throw const RunnerDiscoveryException(
          'No Serverpod server package was found in this folder.',
        );
      }
      _serverDir = serverDir;

      final resolution = await _settle(serverDir, cancelled);
      if (cancelled()) return;
      switch (resolution) {
        case IncompatibleRunner(:final message):
          throw RunnerDiscoveryException(message);
        case LiveRunner(:final manifest, :final socketPath):
          final owned = await readOwnedRunner();
          _owned = owned?.matches(serverDir, manifest.pid) ?? false;
          _pid = manifest.pid;
          log.addLocal(
            _owned
                ? 'Reattaching to the Serverpod runner App Studio started '
                    '(pid ${manifest.pid}).'
                : 'Attaching to the Serverpod runner already running for this '
                    'project (pid ${manifest.pid}). It was started outside App '
                    'Studio, so closing the project leaves it running.',
          );
          await _attach(socketPath, epoch);
        case NoRunner():
          _preparing = true;
          notifyListeners();
          await (_resolveDependencies ?? _pubGet)(
            projectPath,
            log,
            cancelled,
          );
          if (cancelled()) return;
          _preparing = false;
          notifyListeners();
          final socketPath = await _launchRunner(serverDir, cancelled);
          if (socketPath == null || cancelled()) return;
          await _attach(socketPath, epoch);
      }
    } catch (e) {
      if (cancelled()) return;
      _fail('$e');
    } finally {
      if (epoch == _epoch) {
        _starting = false;
        _preparing = false;
        notifyListeners();
      }
    }
  }

  Future<void> _pubGet(
    String projectPath,
    RunnerLog log,
    bool Function() isCancelled,
  ) =>
      resolveProjectDependencies(
        projectPath,
        toolchain: toolchains.current,
        log: log,
        isCancelled: isCancelled,
      );

  /// Resolves the runner, waiting out one that is shutting down: it holds the
  /// package's lock until it has gone, and a runner started meanwhile would
  /// die on it.
  Future<RunnerResolution> _settle(
    String serverDir,
    bool Function() cancelled, {
    Duration patience = const Duration(seconds: 15),
  }) async {
    final waited = Stopwatch()..start();
    while (true) {
      final resolution = await resolveRunner(serverDir);
      final inTransit = switch (resolution) {
        LiveRunner(:final manifest) => manifest.stage == RunnerStage.stopping,
        _ => false,
      };
      if (!inTransit || waited.elapsed > patience || cancelled()) {
        return resolution;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  /// Runs `serverpod runner start` and waits for the runner it spawns to
  /// answer. Returns its socket, or null when cancelled.
  ///
  /// The CLI's public way up, rather than spawning the hidden `runner serve`
  /// ourselves: it handles the lock, a runner another client is starting at
  /// the same moment, and the options a running one was started with. It
  /// returns only once the whole stack is up — minutes on a cold project — but
  /// the runner answers within seconds of being spawned, so this attaches as
  /// soon as it does and lets the CLI finish on its own.
  Future<String?> _launchRunner(
    String serverDir,
    bool Function() cancelled,
  ) async {
    log.addLocal('serverpod runner start');
    final launch = await _launcher(
      toolchain: toolchains.current,
      serverDir: serverDir,
    );
    _launch = launch;
    _owned = true;

    var attached = false;
    final output = <String>[];
    unawaited(
      launch.output.forEach((line) {
        final plain = stripAnsi(line);
        if (_runnerPid.firstMatch(plain) case final match?) {
          _pid ??= int.tryParse(match[1]!);
        }
        output.add(plain);
        // Once attached the runner's own log takes over, and this would only
        // repeat it.
        if (!attached && plain.trim().isNotEmpty) log.addLocal(plain);
      }).catchError((_) {}),
    );
    int? exitCode;
    unawaited(launch.exitCode.then((code) => exitCode = code));

    while (true) {
      if (cancelled()) return null;
      final resolution = await resolveRunner(serverDir);
      if (resolution case LiveRunner(:final manifest, :final socketPath)
          when manifest.stage != RunnerStage.stopping) {
        attached = true;
        _pid = manifest.pid;
        await recordOwnedRunner(
          OwnedRunner(serverDir: serverDir, pid: manifest.pid),
        );
        return socketPath;
      }
      if (resolution case IncompatibleRunner(:final message)) {
        throw RunnerDiscoveryException(message);
      }
      if (exitCode != null) {
        _launch = null;
        throw Exception(
          'The Serverpod runner did not start (`serverpod runner start` exited '
          'with code $exitCode). The server log has its output.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<void> _attach(String socketPath, int epoch) async {
    final client = await RunnerClient.connect(socketPath);
    if (epoch != _epoch) {
      await client.close();
      return;
    }
    _client = client;
    _eventSub = client.events.listen(_onEvent);
    await client.attach((snapshot) {
      log.applySnapshot(snapshot);
      _stage = snapshot.stage;
      _exitCode = snapshot.exitCode;
      _canLaunchFlutterApps = snapshot.canLaunchFlutterApps;
      _syncPreviewUrl();
    });
    unawaited(client.done.then((_) => _onDisconnected(client)));
    notifyListeners();
    _launchPreviewAppIfIdle();
  }

  void _onEvent(RunnerEvent event) {
    log.applyEvent(event);
    var changed = false;
    switch (event) {
      case StageChangedEvent(:final stage, :final exitCode):
        changed = _stage != stage;
        _stage = stage;
        _exitCode = exitCode ?? _exitCode;
      case ServerLogEvent(:final record):
        if (parseRegistrationCode(record.message) case final code?) {
          _registrationCode = code;
          changed = true;
        }
      case FlutterAppStateEvent() || FlutterAppsChangedEvent():
        // Launching → running moves the phase even with no URL change.
        changed = true;
      case _:
        break;
    }
    changed = _syncPreviewUrl() || changed;
    // Only phase-level changes notify: every listener of this controller
    // rebuilds the shell, and a busy server logs many times a second. The log
    // pane listens to [log] for the rest.
    if (changed) notifyListeners();
    _launchPreviewAppIfIdle();
  }

  /// Takes the preview app's URL, and whether that moved.
  bool _syncPreviewUrl() {
    final url = previewApp?.status.url;
    if (url == _previewUrl) return false;
    _previewUrl = url;
    // A new URL is a new page, so the app has to come up in it again.
    _live = false;
    return true;
  }

  /// Launches the preview app once per attach if the runner has not.
  ///
  /// Only `auto_launch` apps start by themselves, and a project created
  /// outside App Studio may not have it. The runner ignores a launch for an
  /// app already starting, so racing its own auto-launch is harmless.
  void _launchPreviewAppIfIdle() {
    final client = _client;
    final app = previewApp;
    if (client == null ||
        app == null ||
        _launchRequested ||
        !_canLaunchFlutterApps ||
        _stage != RunnerStage.running ||
        app.status.running ||
        app.status.launching) {
      return;
    }
    _launchRequested = true;
    unawaited(
      client.launchFlutterApp(app.id).catchError((Object e) {
        log.addLocal(
          'Could not launch ${app.name}.',
          level: RunnerLogLevel.warning,
          error: '$e',
        );
      }),
    );
  }

  Future<void> _onDisconnected(RunnerClient client) async {
    if (!identical(client, _client) || _stopping) return;
    await _eventSub?.cancel();
    _eventSub = null;
    final serverDir = _serverDir;
    final epoch = _epoch;

    // `_client` stays put while this decides what the drop means, so the
    // state does not flicker to idle on the way to "reattached" or "failed".
    if (serverDir != null) {
      final resolution = await resolveRunner(serverDir);
      if (epoch != _epoch || !identical(client, _client)) return;
      // The connection dropped under a live runner — a socket hiccup, not a
      // shutdown. Take a fresh snapshot.
      if (resolution case LiveRunner(:final manifest, :final socketPath)
          when manifest.stage != RunnerStage.stopping) {
        _client = null;
        try {
          await _attach(socketPath, epoch);
          return;
        } catch (_) {}
      }
      if (resolution case NoRunner(staleManifest: final manifest?)) {
        _exitCode = manifest.exitCode ?? _exitCode;
      }
    }

    // It has gone. Whoever stopped it, the session is over.
    final exitCode = _exitCode;
    final wasOwned = _owned;
    _resetRunner();
    if (exitCode == 0) {
      log.addLocal('The Serverpod runner was stopped outside App Studio.');
    } else {
      _fail(
        exitCode == null
            ? 'The Serverpod runner stopped unexpectedly.'
            : 'The Serverpod runner stopped with exit code $exitCode.',
      );
    }
    notifyListeners();
    if (wasOwned) await clearOwnedRunner();
  }

  /// Stops the runner, waits for it to be gone, then starts a fresh one.
  ///
  /// A runner that failed to build is asked to retry instead — it is still
  /// up, and rebuilding is the part that needs doing. Starting from
  /// [ProcessState.idle] is a plain start: after a crash there is nothing to
  /// stop, and refusing to act would leave the one button that fixes it doing
  /// nothing.
  ///
  /// The stop applies to a runner App Studio found as much as to one it
  /// started — the user asked for a restart — and the runner that replaces it
  /// is App Studio's.
  @override
  Future<void> restart() async {
    final projectPath = session.projectPath;
    if (projectPath == null || isTransitioning) return;

    _restarting = true;
    notifyListeners();
    try {
      final client = _client;
      if (client != null && _stage == RunnerStage.degraded) {
        _error = null;
        log.addLocal('Retrying the build.');
        await client.retryStart();
        return;
      }
      if (_client != null || _launch != null) {
        _owned = true;
        await stop();
      }
      if (session.projectPath != projectPath) return;
      await start();
    } catch (e) {
      _fail('$e');
    } finally {
      _restarting = false;
      notifyListeners();
    }
  }

  /// Hard-reloads the CEF preview, ignoring its cache.
  ///
  /// One reload path, and it is always the hard one — a plain navigation
  /// re-serves the cached `main.dart.js`, so a rebuilt app would look
  /// unchanged.
  void requestPreviewReload() {
    if (!previewReady) return;
    _previewReloadToken++;
    notifyListeners();
  }

  /// Stops a runner App Studio started, or detaches from one it found.
  ///
  /// Awaitable on purpose: `teardownSession` waits on it, so a quit or an
  /// update never leaves a runner of ours behind with nobody to stop it.
  Future<void> stop() async {
    if (_stopping) return _stopDone?.future;
    if (state == ProcessState.idle && _launch == null) return;

    _epoch++;
    _stopping = true;
    final done = _stopDone = Completer<void>();
    notifyListeners();
    try {
      final client = _client;
      if (client != null && _owned) {
        log.addLocal('Stopping the Serverpod runner.');
        try {
          await client.stop();
          await client.done.timeout(const Duration(seconds: 15));
        } catch (_) {
          _signalRunner();
        }
        await clearOwnedRunner();
      } else if (client != null) {
        log.addLocal(
          'Detached from the Serverpod runner. It keeps running, since App '
          'Studio did not start it.',
        );
        await client.close();
      } else if (_launch != null) {
        // Started but never attached: the CLI is still waiting for its
        // runner, and the runner may already exist.
        _launch?.kill();
        _signalRunner();
        await clearOwnedRunner();
      }
    } finally {
      _resetRunner();
      _error = null;
      _stopping = false;
      notifyListeners();
      done.complete();
    }
  }

  /// The runner by signal, for when its socket cannot ask it. It handles
  /// SIGTERM as a graceful shutdown.
  void _signalRunner() {
    final pid = _pid;
    if (pid == null || pid <= 0) return;
    try {
      Process.killPid(pid, ProcessSignal.sigterm);
    } catch (_) {}
  }

  void _resetRunner() {
    unawaited(_eventSub?.cancel());
    _eventSub = null;
    final client = _client;
    _client = null;
    if (client != null && !client.isClosed) unawaited(client.close());
    _launch = null;
    _stage = null;
    _exitCode = null;
    _owned = false;
    _pid = null;
    _previewUrl = null;
    _live = false;
    _registrationCode = null;
    _starting = false;
    _preparing = false;
    log.detach();
  }

  void _fail(String message) {
    _error = message;
    log.addLocal(message, level: RunnerLogLevel.error);
    notifyListeners();
  }

  /// Called by the preview pane once the Flutter app's `main()` is running in
  /// the page it loaded.
  void markPreviewLive() {
    if (!previewReady || _live) return;
    _live = true;
    _error = null;
    notifyListeners();
  }

  /// Clears the registration code banner (user dismissed it).
  void dismissRegistrationCode() {
    if (_registrationCode == null) return;
    _registrationCode = null;
    notifyListeners();
  }

  @override
  Future<void> hotReload() async {
    if (!canHotReload) return;
    await _run(RunnerAction.hotReload, (client) => client.hotReload());
  }

  /// The runner answers once the server has rebooted and every Flutter app has
  /// restarted, so the reload lands on the new build. It also triggers a
  /// browser refresh of its own, but through DWDS, which leaves the cached
  /// `main.dart.js` in place — so the preview is hard-reloaded here as well.
  /// Only on success: reloading after a failed restart would re-serve the old
  /// app and make it look like the restart worked.
  @override
  Future<void> hotRestart() async {
    if (!canHotReload) return;
    final ok = await _run(RunnerAction.hotRestart, (client) async {
      await client.hotRestart();
      return true;
    });
    if (ok ?? false) requestPreviewReload();
  }

  @override
  Future<MigrationResult?> createMigration({bool force = false}) =>
      _migration(
        RunnerAction.createMigration,
        (client) => client.createMigration(force: force),
      );

  @override
  Future<MigrationResult?> createRepairMigration({bool force = false}) =>
      _migration(
        RunnerAction.createRepairMigration,
        (client) => client.createRepairMigration(force: force),
      );

  @override
  Future<void> applyMigrations() async {
    if (!canMigrate) return;
    await _run(RunnerAction.applyMigrations, (client) async {
      await client.applyMigrations();
      return true;
    });
  }

  Future<MigrationResult?> _migration(
    RunnerAction action,
    Future<MigrationResult> Function(RunnerClient client) body,
  ) async {
    if (!canMigrate) return null;
    final result = await _run(action, body);
    if (result != null && result.isError && !result.abortedForWarnings) {
      _failedAction = action;
      _actionError = result.message;
      notifyListeners();
    }
    return result;
  }

  Future<T?> _run<T>(
    RunnerAction action,
    Future<T> Function(RunnerClient client) body,
  ) async {
    final client = _client;
    if (client == null || _runningAction != null) return null;
    _runningAction = action;
    _failedAction = null;
    _actionError = null;
    notifyListeners();
    try {
      return await body(client);
    } catch (e) {
      _failedAction = action;
      _actionError = '$e';
      log.addLocal(
        '${action.label} failed.',
        level: RunnerLogLevel.error,
        error: '$e',
      );
      return null;
    } finally {
      _runningAction = null;
      notifyListeners();
    }
  }

  bool _disposed = false;

  /// A runner outlives this controller's listeners: a stop or a disconnect can
  /// finish after `dispose()`, and has nobody left to tell.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    session.removeListener(_onSessionChanged);
    if (canStop) unawaited(stop());
    _disposed = true;
    super.dispose();
  }
}

/// Starts `serverpod runner start --directory <serverDir>`.
///
/// The `--directory` is the server package, which App Studio finds itself
/// ([findServerDirectory]): given anything else the CLI would search from its
/// working directory, and could settle on a different package than the one
/// whose manifest App Studio watches.
///
/// An ordinary child, not a PTY. The runner it spawns is detached by the CLI,
/// so this process exits once the stack is up and nothing of ours depends on
/// it after that.
Future<RunnerLaunch> launchRunnerProcess({
  required Toolchain toolchain,
  required String serverDir,
}) async {
  final serverpod = toolchain.serverpodExecutable;
  if (serverpod == null) {
    throw Exception(toolchain.unavailableReason(ToolId.serverpodCli));
  }
  final process = await Process.start(
    serverpod,
    ['runner', 'start', '--directory', serverDir],
    workingDirectory: serverDir,
    environment: {
      ...toolchain.processEnvironment(),
      // Nothing renders escape codes any more; keep them out of the log. The
      // runner, the pod and `flutter run` inherit this.
      'TERM': 'dumb',
    }..removeWhere((key, _) => key == 'COLORTERM' || key == 'COLORFGBG'),
    includeParentEnvironment: false,
  );
  final lines = StreamController<String>();
  var open = 2;
  for (final stream in [process.stdout, process.stderr]) {
    stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(lines.add, onDone: () {
      if (--open == 0) unawaited(lines.close());
    });
  }
  return RunnerLaunch(
    output: lines.stream,
    exitCode: process.exitCode,
    kill: process.kill,
  );
}
