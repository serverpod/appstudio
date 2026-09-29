import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../process/dev_session_cleanup.dart';
import '../toolchain/tool_probe.dart';
import '../toolchain/toolchain_controller.dart';

enum OpenCodeServeState { stopped, starting, running, stopping }

/// Spawns `opencode serve` bound to a project directory.
class OpenCodeServe {
  OpenCodeServe({required this.toolchains});

  final ToolchainController toolchains;

  Process? _process;
  OpenCodeServeState _state = OpenCodeServeState.stopped;
  Uri? _baseUrl;
  String? _projectPath;
  String? _error;
  final _stdout = StringBuffer();

  /// Bumped by every [start] and every [stop].
  ///
  /// This is what makes a superseded start clean up after itself. The handle is
  /// published two awaits after `Process.start` is called, so a second start
  /// arriving in that window used to find `_process == null`, kill nothing, and
  /// then overwrite the handle when the first one finally published — stranding
  /// a live `opencode serve` that nothing could ever reach again. Each start now
  /// checks that it is still the current one and kills its own process if not.
  int _generation = 0;

  OpenCodeServeState get state => _state;
  Uri? get baseUrl => _baseUrl;
  String? get projectPath => _projectPath;
  String? get error => _error;
  bool get isRunning => _state == OpenCodeServeState.running && _baseUrl != null;

  Future<Uri> start(String projectPath) async {
    if (_state == OpenCodeServeState.running &&
        _projectPath == projectPath &&
        _baseUrl != null) {
      return _baseUrl!;
    }
    await stop();

    final generation = ++_generation;
    _state = OpenCodeServeState.starting;
    _error = null;
    _projectPath = projectPath;
    _stdout.clear();

    final toolchain = toolchains.current;
    // App Studio no longer installs OpenCode, so the agent runs whichever copy
    // the user has on their PATH.
    final opencode =
        await whichOnPath('opencode', Platform.environment['PATH']);
    if (opencode == null) {
      _state = OpenCodeServeState.stopped;
      _error = 'OpenCode is not installed. Install it and make sure '
          '`opencode` is on your PATH.';
      throw StateError(_error!);
    }

    final port = await _freePort();
    final env = toolchain.processEnvironment();
    // Avoid password prompt / leave local-only unsecured (loopback).
    env.remove('OPENCODE_SERVER_PASSWORD');

    final Process process;
    try {
      process = await Process.start(
        opencode,
        [
          'serve',
          '--hostname',
          '127.0.0.1',
          '--port',
          '$port',
        ],
        workingDirectory: projectPath,
        environment: env,
        runInShell: false,
      );
    } catch (e) {
      if (generation == _generation) {
        _state = OpenCodeServeState.stopped;
        _error = 'Failed to start opencode: $e';
      }
      rethrow;
    }

    // Superseded while spawning. Nothing else holds this handle, so if it is not
    // killed here it is orphaned for the life of the machine.
    if (generation != _generation) {
      await _reap(process);
      throw StateError('opencode start was superseded');
    }

    _process = process;
    // Registered before the health check: a process that is up but not yet
    // answering is exactly the one a crash would strand.
    await registerDevSessionPid(DevProcessKind.agent, process.pid);

    process.stdout.transform(utf8.decoder).listen((chunk) {
      _stdout.write(chunk);
    });
    process.stderr.transform(utf8.decoder).listen((chunk) {
      _stdout.write(chunk);
    });
    unawaited(process.exitCode.then((code) {
      if (_process == process) {
        _state = OpenCodeServeState.stopped;
        _baseUrl = null;
        _error ??= 'opencode exited with code $code';
        unawaited(clearDevSessionPid(DevProcessKind.agent));
      }
    }));

    final base = Uri.parse('http://127.0.0.1:$port');
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (generation != _generation || _process != process) {
        // Same reasoning as above: whoever superseded us could not have killed
        // this process, so it is ours to clean up.
        await _reap(process);
        throw StateError(_error ?? 'opencode stopped while starting');
      }
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(milliseconds: 400);
        final req = await client.getUrl(base.replace(path: '/global/health'));
        final res = await req.close().timeout(const Duration(milliseconds: 800));
        final body = await res.transform(utf8.decoder).join();
        client.close(force: true);
        if (res.statusCode == 200 && body.contains('healthy')) {
          _baseUrl = base;
          _state = OpenCodeServeState.running;
          return base;
        }
      } catch (_) {
        // keep polling
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    await stop();
    _error = 'Timed out waiting for opencode serve';
    throw StateError(_error!);
  }

  /// Stops the serve and waits for the process to actually be gone.
  ///
  /// Awaiting matters: callers use this to guarantee the port is free before the
  /// next start, and the quit path uses it to guarantee we are not leaving a
  /// child behind. Bumping the generation also cancels any start still in
  /// flight, which then kills its own process.
  Future<void> stop() async {
    _generation++;
    final process = _process;
    if (process == null) {
      _state = OpenCodeServeState.stopped;
      _baseUrl = null;
      await clearDevSessionPid(DevProcessKind.agent);
      return;
    }
    _state = OpenCodeServeState.stopping;
    _process = null;
    await _reap(process);
    _state = OpenCodeServeState.stopped;
    _baseUrl = null;
    await clearDevSessionPid(DevProcessKind.agent);
  }

  Future<void> dispose() => stop();

  /// SIGTERM, wait, then SIGKILL — and wait again, so this returns only once the
  /// process is really reaped rather than once a signal has been sent.
  static Future<void> _reap(Process process) async {
    try {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(const Duration(seconds: 3));
      return;
    } on TimeoutException {
      // Ignored it. Escalate below.
    } catch (_) {
      return;
    }
    try {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  static Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }
}
