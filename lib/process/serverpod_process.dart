import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../preview/preview_phase.dart';
import '../process/dev_session_cleanup.dart';
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
  }) {
    session.addListener(_onSessionChanged);
    _onSessionChanged();
  }

  final Toolchain toolchain;
  final ProjectSession session;
  final StudioTerminal terminal;

  ProcessState _state = ProcessState.idle;
  PreviewPhase _phase = PreviewPhase.idle;
  bool _previewReady = false;
  int _previewReloadToken = 0;
  String? _error;
  String? _boundProjectPath;
  int _epoch = 0;
  Timer? _pollTimer;
  VoidCallback? _terminalListener;
  StreamSubscription<String>? _outputSub;
  final _outputBuffer = StringBuffer();
  bool _scheduledVmServiceReload = false;

  ProcessState get state => _state;
  PreviewPhase get phase => _phase;

  /// Web server is accepting connections on :9998 (CEF may load).
  bool get previewReady => _previewReady;

  /// Increments when the preview should reload (DWDS/VM service attach).
  int get previewReloadToken => _previewReloadToken;

  /// True after Serverpod has started connecting to the Flutter VM service.
  bool get hasAttachedFlutter => _scheduledVmServiceReload;

  /// Last process failure message, if any.
  String? get error => _error;

  bool get canStart => session.hasProject && _state == ProcessState.idle;
  bool get canStop =>
      _state == ProcessState.running || _state == ProcessState.starting;

  void _onSessionChanged() {
    final path = session.projectPath;
    if (path == null) {
      _boundProjectPath = null;
      unawaited(stop());
      return;
    }
    if (path == _boundProjectPath &&
        (_state == ProcessState.running || _state == ProcessState.starting)) {
      return;
    }
    unawaited(_startForProject(path));
  }

  Future<void> _startForProject(String projectPath) async {
    final epoch = ++_epoch;
    if (canStop) {
      await stop();
    }
    if (epoch != _epoch || session.projectPath != projectPath) return;

    _boundProjectPath = projectPath;
    await start();
  }

  Future<void> start() async {
    final projectPath = session.projectPath;
    if (projectPath == null) return;
    if (_state == ProcessState.starting || _state == ProcessState.running) {
      return;
    }

    _error = null;
    _previewReady = false;
    _scheduledVmServiceReload = false;
    _outputBuffer.clear();
    _setPhase(ProcessState.starting, PreviewPhase.startingServerpod);

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
      _setPhase(ProcessState.running, PreviewPhase.waitingForServer);
      _startPolling();
    } catch (e) {
      _error = e.toString();
      _previewReady = false;
      _setPhase(ProcessState.idle, PreviewPhase.failed);
    }
  }

  Future<void> stop() async {
    if (_state == ProcessState.idle || _state == ProcessState.stopping) return;
    _setPhase(ProcessState.stopping, PreviewPhase.stopping);
    _stopPolling();
    await terminal.stop();
    _onProcessExited();
  }

  /// Called by the preview pane once the Flutter web app is actually running.
  ///
  /// Ignored until DWDS has attached at least once — the first CEF load is
  /// usually a blank page until the VM-service reload completes.
  void markPreviewLive() {
    if (_state != ProcessState.running || !_previewReady) return;
    if (_phase == PreviewPhase.ready) return;
    // Stay on loading/connecting overlay until attach + reload have happened.
    if (!_scheduledVmServiceReload) return;
    _phase = PreviewPhase.ready;
    _error = null;
    notifyListeners();
  }

  void _onProcessExited() {
    final wasStopping = _state == ProcessState.stopping;
    _stopPolling();
    unawaited(_outputSub?.cancel());
    _outputSub = null;
    _previewReady = false;
    _scheduledVmServiceReload = false;
    _outputBuffer.clear();
    if (wasStopping) {
      _error = null;
      _setPhase(ProcessState.idle, PreviewPhase.idle);
      return;
    }
    // Unexpected exit while starting/running.
    _error ??= 'Serverpod stopped unexpectedly';
    _setPhase(ProcessState.idle, PreviewPhase.failed);
  }

  void _onTerminalOutput(String chunk) {
    _outputBuffer.write(chunk);
    if (_scheduledVmServiceReload) return;

    final plain = _outputBuffer.toString().replaceAll(_ansiEscape, '');
    if (!_vmServiceConnecting.hasMatch(plain)) return;

    _scheduledVmServiceReload = true;
    _previewReloadToken++;
    _phase = PreviewPhase.connecting;
    notifyListeners();
  }

  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 750), (_) async {
      if (_state != ProcessState.running) return;
      final ready = await _tcpReady(kPreviewPort);
      if (ready && !_previewReady) {
        _previewReady = true;
        _phase = PreviewPhase.loadingApp;
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

  void _setPhase(ProcessState state, PreviewPhase phase) {
    _state = state;
    _phase = phase;
    notifyListeners();
  }

  @override
  void dispose() {
    session.removeListener(_onSessionChanged);
    _stopPolling();
    unawaited(_outputSub?.cancel());
    if (_terminalListener != null) {
      terminal.removeListener(_terminalListener!);
    }
    if (canStop) {
      unawaited(stop());
    }
    super.dispose();
  }
}
