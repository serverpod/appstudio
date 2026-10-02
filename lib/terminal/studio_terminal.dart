import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kyroon_pty/kyroon_pty.dart';
import 'package:xterm/xterm.dart';

import '../process/dev_session_cleanup.dart';

class StudioTerminal extends ChangeNotifier {
  StudioTerminal() {
    terminal = Terminal(
      maxLines: 10000,
      // The log is output only, so no key is translated for the PTY: with the
      // default handler Enter, Tab, the arrows and Ctrl chords are written to
      // the server and reported handled, which keeps them from anything else
      // in the window. `onOutput` stays — the terminal's own answers to the
      // program's queries go through it too.
      inputHandler: null,
      onOutput: _writeToPty,
      onResize: (width, height, pixelWidth, pixelHeight) {
        _resizePty(width, height);
      },
    );
  }

  late final Terminal terminal;
  Pty? _pty;
  StreamSubscription<List<int>>? _outputSub;
  final _outputController = StreamController<String>.broadcast();
  bool _running = false;

  bool get isRunning => _running;
  /// Raw PTY stdout/stderr chunks (includes ANSI). Broadcast; late listeners
  /// only see future output.
  Stream<String> get output => _outputController.stream;
  int get cols => terminal.viewWidth > 0 ? terminal.viewWidth : 80;
  int get rows => terminal.viewHeight > 0 ? terminal.viewHeight : 24;

  Future<void> spawn({
    required String executable,
    List<String> arguments = const [],
    required String workingDirectory,
    required Map<String, String> environment,
    bool clearScreen = true,
  }) async {
    await stop();
    if (clearScreen) {
      terminal.write('\x1bc');
    }

    final pty = Pty.start(
      executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      rows: rows,
      columns: cols,
    );
    _pty = pty;
    _running = true;
    await registerDevSessionPid(DevProcessKind.server, pty.pid);
    notifyListeners();

    _outputSub = pty.output.listen((data) {
      final text = utf8.decode(data, allowMalformed: true);
      terminal.write(text);
      if (!_outputController.isClosed) {
        _outputController.add(text);
      }
    });

    unawaited(
      pty.exitCode.then((_) {
        if (!identical(_pty, pty)) return;
        _running = false;
        _pty = null;
        notifyListeners();
      }),
    );
  }

  Future<void> stop() async {
    final pty = _pty;
    if (pty == null) return;

    final pid = pty.pid;
    pty.kill(ProcessSignal.sigterm);
    if (Platform.isMacOS || Platform.isLinux) {
      try {
        Process.killPid(-pid, ProcessSignal.sigterm);
      } catch (_) {}
    }
    try {
      await pty.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      pty.kill(ProcessSignal.sigkill);
      if (Platform.isMacOS || Platform.isLinux) {
        try {
          Process.killPid(-pid, ProcessSignal.sigkill);
        } catch (_) {}
      }
      try {
        await pty.exitCode.timeout(const Duration(seconds: 1));
      } catch (_) {}
    } catch (_) {}

    await _outputSub?.cancel();
    _outputSub = null;
    _pty = null;
    _running = false;
    await clearDevSessionPid(DevProcessKind.server);
    notifyListeners();
  }

  /// Append text to the terminal UI (and broadcast stream) without a PTY.
  void writeLocal(String text) {
    terminal.write(text);
    if (!_outputController.isClosed) {
      _outputController.add(text);
    }
  }

  void _writeToPty(String data) {
    final pty = _pty;
    if (pty == null) return;
    pty.write(utf8.encode(data));
  }

  void _resizePty(int width, int height) {
    // xterm reports (cols, rows); kyroon_pty.resize expects (rows, cols).
    _pty?.resize(height, width);
  }

  @override
  void dispose() {
    unawaited(stop());
    unawaited(_outputController.close());
    super.dispose();
  }
}
