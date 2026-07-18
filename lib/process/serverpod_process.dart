import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../session/project_session.dart';
import '../terminal/studio_terminal.dart';
import '../toolchain/toolchain.dart';

enum ProcessState { idle, starting, running, stopping }

/// Matches Serverpod's progress line for any Flutter app name, e.g.
/// `Connecting to Example app VM service`.
final _vmServiceConnecting = RegExp(
  r'Connecting to .+ VM service',
  caseSensitive: false,
);

final _ansiEscape = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');

class ServerpodProcessController extends ChangeNotifier {
  ServerpodProcessController({
    required this.toolchain,
    required this.session,
    required this.terminal,
  });

  final Toolchain toolchain;
  final ProjectSession session;
  final StudioTerminal terminal;

  ProcessState _state = ProcessState.idle;
  bool _previewReady = false;
  int _previewReloadToken = 0;
  String _statusMessage = 'Idle';
  Timer? _pollTimer;
  VoidCallback? _terminalListener;
  StreamSubscription<String>? _outputSub;
  final _outputBuffer = StringBuffer();
  bool _scheduledVmServiceReload = false;

  ProcessState get state => _state;
  /// Web server is accepting connections on :9998 (CEF may load).
  bool get previewReady => _previewReady;
  /// Increments when the preview should reload (DWDS/VM service attach).
  int get previewReloadToken => _previewReloadToken;
  String get statusMessage => _statusMessage;
  bool get canStart => session.hasProject && _state == ProcessState.idle;
  bool get canStop =>
      _state == ProcessState.running || _state == ProcessState.starting;

  Future<void> start() async {
    final projectPath = session.projectPath;
    if (projectPath == null) return;
    if (_state == ProcessState.starting || _state == ProcessState.running) {
      return;
    }

    _setState(ProcessState.starting, 'Starting serverpod…');
    _previewReady = false;
    _scheduledVmServiceReload = false;
    _outputBuffer.clear();
    notifyListeners();

    _terminalListener ??= () {
      if (!terminal.isRunning &&
          (_state == ProcessState.running || _state == ProcessState.starting)) {
        _onProcessExited();
      }
    };
    terminal.addListener(_terminalListener!);

    await _outputSub?.cancel();
    _outputSub = terminal.output.listen(_onTerminalOutput);

    try {
      await terminal.spawn(
        executable: toolchain.serverpodExecutable,
        arguments: const ['start', '--no-tui'],
        workingDirectory: projectPath,
        environment: toolchain.processEnvironment(),
      );
      _setState(ProcessState.running, 'Running · probing :9998');
      _startPolling();
    } catch (e) {
      _setState(ProcessState.idle, 'Failed to start: $e');
      _previewReady = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    if (_state == ProcessState.idle || _state == ProcessState.stopping) return;
    _setState(ProcessState.stopping, 'Stopping…');
    _stopPolling();
    await terminal.stop();
    _onProcessExited();
  }

  void _onProcessExited() {
    _stopPolling();
    unawaited(_outputSub?.cancel());
    _outputSub = null;
    _previewReady = false;
    _scheduledVmServiceReload = false;
    _outputBuffer.clear();
    _setState(ProcessState.idle, 'Idle');
  }

  void _onTerminalOutput(String chunk) {
    _outputBuffer.write(chunk);
    if (_scheduledVmServiceReload) return;

    final plain = _outputBuffer.toString().replaceAll(_ansiEscape, '');
    if (!_vmServiceConnecting.hasMatch(plain)) return;

    _scheduledVmServiceReload = true;
    _previewReloadToken++;
    _statusMessage = 'Preview · VM service attaching · reloading';
    notifyListeners();
  }

  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 750), (_) async {
      if (_state != ProcessState.running) return;
      final ready = await _tcpReady(9998);
      if (ready && !_previewReady) {
        _previewReady = true;
        _statusMessage = 'Preview · :9998 up · waiting for Flutter attach';
        notifyListeners();
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<bool> _tcpReady(int port) async {
    try {
      final socket = await Socket.connect(
        '127.0.0.1',
        port,
        timeout: const Duration(milliseconds: 400),
      );
      await socket.close();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _setState(ProcessState state, String message) {
    _state = state;
    _statusMessage = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _stopPolling();
    unawaited(_outputSub?.cancel());
    if (_terminalListener != null) {
      terminal.removeListener(_terminalListener!);
    }
    super.dispose();
  }
}
