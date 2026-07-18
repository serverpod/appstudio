import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:kyroon_pty/kyroon_pty.dart';
import 'package:xterm/xterm.dart';

class StudioTerminal extends ChangeNotifier {
  StudioTerminal() {
    terminal = Terminal(
      maxLines: 10000,
      onOutput: _writeToPty,
      onResize: (width, height, pixelWidth, pixelHeight) {
        _resizePty(width, height);
      },
    );
  }

  late final Terminal terminal;
  Pty? _pty;
  StreamSubscription<List<int>>? _outputSub;
  bool _running = false;

  bool get isRunning => _running;
  int get cols => terminal.viewWidth > 0 ? terminal.viewWidth : 80;
  int get rows => terminal.viewHeight > 0 ? terminal.viewHeight : 24;

  Future<void> spawn({
    required String executable,
    List<String> arguments = const [],
    required String workingDirectory,
    required Map<String, String> environment,
  }) async {
    await stop();
    terminal.write('\x1bc');

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
    notifyListeners();

    _outputSub = pty.output.listen((data) {
      terminal.write(utf8.decode(data, allowMalformed: true));
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

    pty.kill(ProcessSignal.sigterm);
    try {
      await pty.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      pty.kill(ProcessSignal.sigkill);
      try {
        await pty.exitCode.timeout(const Duration(seconds: 1));
      } catch (_) {}
    } catch (_) {}

    await _outputSub?.cancel();
    _outputSub = null;
    _pty = null;
    _running = false;
    notifyListeners();
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
    super.dispose();
  }
}
