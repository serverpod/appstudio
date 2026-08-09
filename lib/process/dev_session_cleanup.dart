import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Preview web-server port (Serverpod `flutter_apps` default).
const kPreviewPort = 9998;

/// A long-lived child process whose pid is written to disk so the *next* launch
/// can reclaim it.
///
/// Best-effort teardown is not enough on its own, for two reasons that no amount
/// of care in `dispose()` fixes: `ChangeNotifier.dispose()` is synchronous and
/// cannot await a process exit, and a hard quit can kill the isolate before any
/// teardown runs at all. Every child that outlives a frame registers here.
enum DevProcessKind {
  /// The `serverpod start` PTY.
  server('server'),

  /// `opencode serve` — the agent.
  agent('agent'),

  /// `serverpod mcp-server` — the Hot Restart bridge.
  mcpBridge('mcp');

  const DevProcessKind(this.id);

  final String id;

  /// Deliberately in the system temp dir: it must survive an isolate restart
  /// but not a reboot, and a stale file is harmless — the pid simply will not
  /// be alive.
  String get pidFile =>
      p.join(Directory.systemTemp.path, 'appstudio-$id.pid');
}

/// Clears orphaned child processes left by a hot restart, a crash or a hard
/// quit.
///
/// Hot restart re-runs [main] without awaiting widget [dispose], so children can
/// outlive the old isolate — and once they do they are reparented to launchd,
/// where nothing else will ever clean them up.
Future<void> cleanupOrphanedDevSession() async {
  await reclaimRegisteredPids();
  await releaseTcpPort(kPreviewPort);
}

/// Kills every child registered by a previous run.
///
/// Split out from [cleanupOrphanedDevSession] deliberately: the other half
/// reclaims port 9998 from whatever holds it, which is the right thing to do on
/// launch and the wrong thing to do from a test on a machine where a real
/// preview server may be serving.
Future<void> reclaimRegisteredPids() async {
  for (final kind in DevProcessKind.values) {
    await _killRegisteredSessionPid(kind);
  }
}

Future<void> registerDevSessionPid(DevProcessKind kind, int pid) async {
  if (pid <= 0) return;
  try {
    await File(kind.pidFile).writeAsString('$pid');
  } catch (_) {}
}

Future<void> clearDevSessionPid(DevProcessKind kind) async {
  try {
    final file = File(kind.pidFile);
    if (await file.exists()) await file.delete();
  } catch (_) {}
}

Future<void> _killRegisteredSessionPid(DevProcessKind kind) async {
  try {
    final file = File(kind.pidFile);
    if (!await file.exists()) return;
    final pid = int.tryParse((await file.readAsString()).trim());
    await file.delete();
    if (pid == null || pid <= 0) return;
    await _killProcessTree(pid);
  } catch (_) {}
}

Future<void> releaseTcpPort(int port) async {
  if (!Platform.isMacOS && !Platform.isLinux) return;

  final pids = await _pidsListeningOnPort(port);
  if (pids.isEmpty) return;

  for (final pid in pids) {
    await _killProcessTree(pid);
  }
}

Future<Set<int>> _pidsListeningOnPort(int port) async {
  try {
    final result = await Process.run('lsof', ['-ti', 'tcp:$port']);
    if (result.exitCode != 0) return {};
    return (result.stdout as String)
        .trim()
        .split('\n')
        .map((line) => int.tryParse(line.trim()))
        .whereType<int>()
        .toSet();
  } catch (_) {
    return {};
  }
}

Future<void> _killProcessTree(int pid) async {
  _signal(pid, ProcessSignal.sigterm);

  await Future<void>.delayed(const Duration(milliseconds: 250));

  if (!await _isProcessAlive(pid)) return;

  _signal(pid, ProcessSignal.sigkill);

  if (kDebugMode) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

/// Signals the process *group* led by [pid] if there is one, and the single
/// process otherwise.
///
/// The fallback has to be driven by the return value, not by an exception.
/// `Process.killPid` reports failure with `false` — it does not throw — so a
/// `try`/`catch` around the group kill never fires and the single-process
/// fallback never runs. That matters because only a child that called `setsid`
/// leads its own group: the `serverpod start` PTY does, so `-pid` reaches its
/// whole tree, but a plain `Process.start` child like `opencode serve` inherits
/// our group and leads nothing, so `-pid` matches nothing at all. Silently. That
/// is exactly how orphaned agents survived every reclaim on launch.
void _signal(int pid, ProcessSignal signal) {
  if (Platform.isMacOS || Platform.isLinux) {
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

Future<bool> _isProcessAlive(int pid) async {
  try {
    final result = await Process.run('kill', ['-0', '$pid']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}
