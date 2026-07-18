import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../session/project_session.dart';
import '../terminal/studio_terminal.dart';
import '../toolchain/toolchain.dart';

enum ProcessState { idle, starting, running, stopping }

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
  String _statusMessage = 'Idle';
  Timer? _pollTimer;
  VoidCallback? _terminalListener;

  ProcessState get state => _state;
  bool get previewReady => _previewReady;
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
    notifyListeners();

    _terminalListener ??= () {
      if (!terminal.isRunning &&
          (_state == ProcessState.running || _state == ProcessState.starting)) {
        _onProcessExited();
      }
    };
    terminal.addListener(_terminalListener!);

    try {
      await terminal.spawn(
        executable: toolchain.serverpodExecutable,
        arguments: const ['start'],
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
    _previewReady = false;
    _setState(ProcessState.idle, 'Idle');
  }

  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 750), (_) async {
      if (_state != ProcessState.running) return;
      final ready = await _httpReady(9998);
      if (ready && !_previewReady) {
        _previewReady = true;
        _statusMessage = 'Preview ready · :9998';
        notifyListeners();
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<bool> _httpReady(int port) async {
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
    if (_terminalListener != null) {
      terminal.removeListener(_terminalListener!);
    }
    super.dispose();
  }
}
