import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../toolchain/tool_status.dart';
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

    _state = OpenCodeServeState.starting;
    _error = null;
    _projectPath = projectPath;
    _stdout.clear();

    final toolchain = toolchains.current;
    final opencode = toolchain.opencodeExecutable;
    if (opencode == null) {
      _state = OpenCodeServeState.stopped;
      _error = toolchain.unavailableReason(ToolId.opencode);
      throw StateError(_error!);
    }

    final port = await _freePort();
    final env = toolchain.processEnvironment();
    // Avoid password prompt / leave local-only unsecured (loopback).
    env.remove('OPENCODE_SERVER_PASSWORD');

    try {
      _process = await Process.start(
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
      _state = OpenCodeServeState.stopped;
      _error = 'Failed to start opencode: $e';
      rethrow;
    }

    final process = _process!;
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
      }
    }));

    final base = Uri.parse('http://127.0.0.1:$port');
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (_process != process) {
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

  Future<void> stop() async {
    final process = _process;
    if (process == null) {
      _state = OpenCodeServeState.stopped;
      _baseUrl = null;
      return;
    }
    _state = OpenCodeServeState.stopping;
    _process = null;
    try {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    } catch (_) {}
    _state = OpenCodeServeState.stopped;
    _baseUrl = null;
  }

  Future<void> dispose() => stop();

  static Future<int> _freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }
}
