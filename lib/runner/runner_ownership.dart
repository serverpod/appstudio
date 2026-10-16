import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../process/process_killer.dart';
import 'runner_client.dart';
import 'runner_discovery.dart';

/// The runner App Studio started, written down so the next launch can stop it.
///
/// A runner is a *detached* daemon — `serverpod runner start` puts it in its
/// own session — so unlike the old `serverpod start` PTY it does not die with
/// us. A normal quit stops it through `teardownSession`; this is the backstop
/// for the quits that never get there: a crash, a `kill -9`, and a Flutter hot
/// restart of App Studio itself, which re-runs `main()` without `dispose()`.
///
/// It is also what makes a runner *ours* rather than one we found: App Studio
/// stops the runners it started and only detaches from the rest, because a
/// runner may belong to the user's terminal or their AI agent. A pid alone is
/// no proof — pids get reused — so a record only matches a live runner whose
/// manifest names the same pid for the same server package.
class OwnedRunner {
  const OwnedRunner({required this.serverDir, required this.pid});

  final String serverDir;
  final int pid;

  bool matches(String serverDir, int pid) =>
      p.equals(this.serverDir, serverDir) && this.pid == pid;
}

/// Deliberately in the system temp dir, beside the agent's pid file: it must
/// survive an isolate restart but not a reboot.
String ownedRunnerRecordPath() =>
    ownedRunnerRecordPathOverride ??
    p.join(Directory.systemTemp.path, 'appstudio-runner.json');

/// Points the record somewhere else, so a test cannot touch the one a running
/// App Studio on the same Mac depends on.
@visibleForTesting
String? ownedRunnerRecordPathOverride;

Future<void> recordOwnedRunner(OwnedRunner runner) async {
  try {
    await File(ownedRunnerRecordPath()).writeAsString(
      jsonEncode({'serverDir': runner.serverDir, 'pid': runner.pid}),
    );
  } catch (_) {}
}

Future<OwnedRunner?> readOwnedRunner() async {
  try {
    final json = jsonDecode(await File(ownedRunnerRecordPath()).readAsString());
    if (json is! Map) return null;
    final serverDir = json['serverDir'];
    final pid = json['pid'];
    if (serverDir is! String || pid is! int) return null;
    return OwnedRunner(serverDir: serverDir, pid: pid);
  } catch (_) {
    return null;
  }
}

Future<void> clearOwnedRunner() async {
  try {
    final file = File(ownedRunnerRecordPath());
    if (await file.exists()) await file.delete();
  } catch (_) {}
}

/// Stops the runner a previous run of App Studio started and never stopped.
///
/// Through its socket when it answers, so it takes its Postgres, Docker
/// services and Flutter apps down with it; by signal when it only holds the
/// pid. Consumes the record either way, so a stale one cannot turn into a
/// signal for whatever process inherits the pid later.
Future<void> reclaimOwnedRunner({
  Duration timeout = const Duration(seconds: 10),
}) async {
  final owned = await readOwnedRunner();
  if (owned == null) return;
  await clearOwnedRunner();
  try {
    switch (await resolveRunner(owned.serverDir)) {
      case LiveRunner(:final manifest, :final socketPath)
          when manifest.pid == owned.pid:
        final client = await RunnerClient.connect(socketPath);
        try {
          await client.stop();
          await client.done.timeout(timeout);
        } finally {
          await client.close();
        }
      case NoRunner(staleManifest: final manifest?)
          when manifest.pid == owned.pid && !manifest.isFinished:
        await const ProcessKiller().requestStop(owned.pid);
      case _:
        break;
    }
  } catch (_) {
    // Best effort: a runner we cannot reach now is one the user can stop with
    // `serverpod runner stop`, and launch must not wait on it.
  }
}
