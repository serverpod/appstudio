import 'dart:io';

import 'package:path/path.dart' as p;

import '../runner/runner_ownership.dart';
import 'process_killer.dart';

/// A long-lived child process whose pid is written to disk so the *next* launch
/// can reclaim it.
///
/// Best-effort teardown is not enough on its own, for two reasons that no amount
/// of care in `dispose()` fixes: `ChangeNotifier.dispose()` is synchronous and
/// cannot await a process exit, and a hard quit can kill the isolate before any
/// teardown runs at all. Every child that outlives a frame registers here.
///
/// The Serverpod runner is not one of these. It is detached by design, so a pid
/// file and a group kill are the wrong tools for it; it gets an ownership
/// record instead ([OwnedRunner]), and is stopped through its socket.
enum DevProcessKind {
  /// `opencode serve` — the agent.
  agent('agent');

  const DevProcessKind(this.id);

  final String id;

  /// Deliberately in the system temp dir: it must survive an isolate restart
  /// but not a reboot, and a stale file is harmless — the pid simply will not
  /// be alive.
  String get pidFile => p.join(Directory.systemTemp.path, 'appstudio-$id.pid');
}

/// Clears orphaned child processes left by a hot restart, a crash or a hard
/// quit.
///
/// Hot restart re-runs [main] without awaiting widget [dispose], so children can
/// outlive the old isolate — and once they do they are reparented to launchd,
/// where nothing else will ever clean them up.
///
/// The runner a previous run started is stopped too — gracefully, over its
/// socket, so its database and Flutter apps go down with it.
Future<void> cleanupOrphanedDevSession() async {
  await reclaimRegisteredPids();
  await reclaimOwnedRunner();
}

/// Kills every child registered by a previous run.
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

Future<void> _killProcessTree(int pid) => const ProcessKiller().stopTree(pid);
