import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/host.dart';

/// Ends processes App Studio started, the way the host allows.
///
/// macOS and Linux have signals: SIGTERM is a request, SIGKILL is not, and a
/// child that leads its own group can be signalled as a whole tree. Windows
/// has none of that — `Process.killPid` there is `TerminateProcess` whatever
/// the signal, and it ends one process, leaving its children (an `opencode`
/// LSP server, the runner's Flutter app) behind.
///
/// **Windows ends the process alone, for now.** Walking the tree with
/// `taskkill /T` blue-screened the Windows dev laptop three times (`0xD1`, a
/// kernel driver), so it is not used. Taking the children with it is Phase 2's
/// job, through a Job Object the children are started in, which needs no tree
/// walk at all.
class ProcessKiller {
  const ProcessKiller({this._host});

  final HostPlatform? _host;

  HostPlatform get host => _host ?? currentHost;

  /// Asks [pid] and everything it started to stop, waits [grace], and forces
  /// whatever is left.
  Future<void> stopTree(
    int pid, {
    Duration grace = const Duration(milliseconds: 250),
  }) async {
    if (pid <= 0) return;
    if (host.isWindows) {
      _terminate(pid);
      return;
    }

    _signal(pid, ProcessSignal.sigterm);

    await Future<void>.delayed(grace);

    if (!await isAlive(pid)) return;

    _signal(pid, ProcessSignal.sigkill);

    if (kDebugMode) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  /// A single, polite request to stop, for a process that handles SIGTERM as
  /// a graceful shutdown. Windows cannot ask a console process, so there it
  /// is ended.
  Future<void> requestStop(int pid) async {
    if (pid <= 0) return;
    if (host.isWindows) {
      _terminate(pid);
      return;
    }
    try {
      Process.killPid(pid, ProcessSignal.sigterm);
    } catch (_) {}
  }

  Future<bool> isAlive(int pid) async {
    if (host.isWindows) {
      try {
        final result = await Process.run('tasklist', [
          '/FI',
          'PID eq $pid',
          '/FO',
          'CSV',
          '/NH',
        ]);
        return '${result.stdout}'.contains('"$pid"');
      } catch (_) {
        return false;
      }
    }
    try {
      final result = await Process.run('kill', ['-0', '$pid']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Signals the process *group* led by [pid] if there is one, and the single
  /// process otherwise.
  ///
  /// The fallback has to be driven by the return value, not by an exception.
  /// `Process.killPid` reports failure with `false` — it does not throw — so
  /// a `try`/`catch` around the group kill never fires and the single-process
  /// fallback never runs. That matters because only a child that called
  /// `setsid` leads its own group: a PTY child does, so `-pid` reaches its
  /// whole tree, but a plain `Process.start` child like `opencode serve`
  /// inherits our group and leads nothing, so `-pid` matches nothing at all.
  /// Silently. That is exactly how orphaned agents survived every reclaim on
  /// launch.
  void _signal(int pid, ProcessSignal signal) {
    if (host.isMacOS || host.os == HostOs.linux) {
      var delivered = false;
      try {
        delivered = Process.killPid(-pid, signal);
      } catch (_) {}
      if (delivered) return;
    }
    try {
      Process.killPid(pid, signal);
    } catch (_) {}
  }

  /// `TerminateProcess`, which is all `Process.killPid` does on Windows.
  void _terminate(int pid) {
    try {
      Process.killPid(pid, ProcessSignal.sigkill);
    } catch (_) {}
  }
}
