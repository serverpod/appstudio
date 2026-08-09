import 'dart:async';

import 'package:flutter/foundation.dart';

import '../process/serverpod_process.dart';
import '../session/project_session.dart';
import '../toolchain/tool_status.dart';
import '../toolchain/toolchain_controller.dart';
import 'hot_restart_view.dart';
import 'serverpod_mcp_bridge.dart';

/// Owns the `serverpod mcp-server` bridge for the open project and exposes the
/// one action App Studio drives through it: hot restart.
///
/// The bridge is only spawned once the server is running, because it is the
/// `serverpod start` runner that opens the socket it forwards to. It is kept up
/// for as long as that runner is, and reports whether a runner is actually
/// attached — which is what gates the toolbar button.
class McpController extends ChangeNotifier implements HotRestartView {
  McpController({
    required this.toolchains,
    required this.session,
    required this.process,
  }) {
    session.addListener(_onSessionOrProcessChanged);
    process.addListener(_onSessionOrProcessChanged);
    _onSessionOrProcessChanged();
  }

  final ToolchainController toolchains;
  final ProjectSession session;
  final ServerpodProcessController process;

  /// How often we ask the bridge whether a runner is attached.
  ///
  /// There is no push for this: the bridge only forwards resource updates from
  /// a runner it is already talking to, so nothing arrives to announce the
  /// runner's *arrival*. A probe is one round trip over a pipe.
  static const _probeInterval = Duration(seconds: 2);

  ServerpodMcpBridge? _bridge;
  McpConnection _connection = McpConnection.idle;
  String? _error;
  bool _hotRestarting = false;
  String? _boundProjectPath;
  Timer? _probeTimer;
  bool _probing = false;
  int _epoch = 0;
  bool _disposed = false;

  @override
  McpConnection get mcpConnection => _connection;

  @override
  bool get isHotRestarting => _hotRestarting;

  @override
  String? get hotRestartError => _error;

  void _onSessionOrProcessChanged() {
    final path = session.projectPath;
    // Gated on the *process*, not on `previewReady`: the runner opens its
    // socket when the server comes up, well before the Flutter app is serving,
    // and a hot restart is worth having as soon as there is a server to
    // restart.
    final wanted = path != null && process.state == ProcessState.running;
    if (!wanted) {
      if (_bridge != null || _connection != McpConnection.idle) {
        unawaited(_teardown());
      }
      return;
    }
    // `process` notifies on every poll tick and phase change, so this has to
    // be idempotent. Anything other than `idle` means a start is already under
    // way or has settled for this project.
    if (path == _boundProjectPath && _connection != McpConnection.idle) return;
    unawaited(_startForProject(path));
  }

  Future<void> _startForProject(String projectPath) async {
    await _teardown(notify: false);
    final epoch = ++_epoch;

    final toolchain = toolchains.current;
    final serverpod = toolchain.serverpodExecutable;
    if (serverpod == null) {
      _connection = McpConnection.unavailable;
      _error = toolchain.unavailableReason(ToolId.serverpodCli);
      _notify();
      return;
    }

    _boundProjectPath = projectPath;
    _connection = McpConnection.connecting;
    _error = null;
    _notify();

    // The same directory `serverpod start` is spawned in, so the bridge runs
    // the same server-package detection and cannot end up pointed at a
    // different project than the one that is running.
    final bridge = ServerpodMcpBridge(
      serverpodExecutable: serverpod,
      workingDirectory: projectPath,
      environment: toolchain.processEnvironment(),
    );
    try {
      await bridge.start();
    } catch (e) {
      await bridge.stop();
      if (epoch != _epoch) return;
      _connection = McpConnection.unavailable;
      _error = '$e';
      _notify();
      return;
    }
    if (epoch != _epoch) {
      await bridge.stop();
      return;
    }

    _bridge = bridge;
    _probeTimer = Timer.periodic(_probeInterval, (_) => unawaited(_probe()));
    await _probe();
  }

  Future<void> _probe() async {
    final bridge = _bridge;
    if (bridge == null || _probing || _hotRestarting) return;

    if (bridge.state == McpBridgeState.stopped) {
      _stopProbing();
      _connection = McpConnection.unavailable;
      final why = bridge.diagnostics;
      _error = why.isEmpty ? 'The Serverpod MCP server stopped.' : why;
      _notify();
      return;
    }

    _probing = true;
    final epoch = _epoch;
    try {
      final attached = await bridge.probeRunnerAttached();
      if (epoch != _epoch || _bridge != bridge) return;
      final next =
          attached ? McpConnection.connected : McpConnection.connecting;
      if (next == _connection) return;
      _connection = next;
      _notify();
    } finally {
      _probing = false;
    }
  }

  @override
  Future<void> hotRestart() async {
    final bridge = _bridge;
    if (bridge == null ||
        _connection != McpConnection.connected ||
        _hotRestarting) {
      return;
    }

    final epoch = _epoch;
    _hotRestarting = true;
    _error = null;
    _notify();

    final outcome = await bridge.hotRestart();
    if (epoch != _epoch) return;

    _hotRestarting = false;
    _error = outcome.isError ? outcome.text : null;
    // The runner went away mid-flight. Fall back to waiting for it rather than
    // leaving a button that looks live but cannot deliver.
    if (outcome.isRunnerMissing) _connection = McpConnection.connecting;
    // The runner reports its own browser refresh once the Flutter app has
    // restarted, but that goes through DWDS and leaves the cached
    // `main.dart.js` in place. Ours ignores the cache, which is the only way to
    // be sure the preview is showing the code that was just compiled.
    if (!outcome.isError) process.requestPreviewReload();
    _notify();
    await _probe();
  }

  /// Stops the bridge and waits for it.
  ///
  /// [dispose] cannot await, so the session teardown calls this instead: a
  /// fire-and-forget stop would let Sparkle relaunch over a bridge that is
  /// still shutting down, leaving a stray process behind.
  Future<void> stop() => _teardown();

  Future<void> _teardown({bool notify = true}) async {
    _epoch++;
    _stopProbing();
    final bridge = _bridge;
    _bridge = null;
    _boundProjectPath = null;
    _connection = McpConnection.idle;
    _error = null;
    _hotRestarting = false;
    if (notify) _notify();
    if (bridge != null) await bridge.stop();
  }

  void _stopProbing() {
    _probeTimer?.cancel();
    _probeTimer = null;
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    session.removeListener(_onSessionOrProcessChanged);
    process.removeListener(_onSessionOrProcessChanged);
    _stopProbing();
    _epoch++;
    final bridge = _bridge;
    _bridge = null;
    if (bridge != null) unawaited(bridge.stop());
    super.dispose();
  }
}
