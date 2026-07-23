import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Preview web-server port (Serverpod `flutter_apps` default).
const kPreviewPort = 9998;

final _sessionPidFile = p.join(
  Directory.systemTemp.path,
  'appstudio-server.pid',
);

/// Clears orphaned serverpod/PTY processes after hot restart or crash.
///
/// Hot restart re-runs [main] without awaiting widget [dispose], so child
/// processes can outlive the old isolate.
Future<void> cleanupOrphanedDevSession() async {
  await _killRegisteredSessionPid();
  await releaseTcpPort(kPreviewPort);
}

Future<void> registerDevSessionPid(int pid) async {
  if (pid <= 0) return;
  try {
    await File(_sessionPidFile).writeAsString('$pid');
  } catch (_) {}
}

Future<void> clearDevSessionPid() async {
  try {
    final file = File(_sessionPidFile);
    if (await file.exists()) await file.delete();
  } catch (_) {}
}

Future<void> _killRegisteredSessionPid() async {
  try {
    final file = File(_sessionPidFile);
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
  if (Platform.isMacOS || Platform.isLinux) {
    try {
      Process.killPid(-pid, ProcessSignal.sigterm);
    } catch (_) {
      try {
        Process.killPid(pid, ProcessSignal.sigterm);
      } catch (_) {}
    }
  } else {
    try {
      Process.killPid(pid, ProcessSignal.sigterm);
    } catch (_) {}
  }

  await Future<void>.delayed(const Duration(milliseconds: 250));

  if (!await _isProcessAlive(pid)) return;

  if (Platform.isMacOS || Platform.isLinux) {
    try {
      Process.killPid(-pid, ProcessSignal.sigkill);
    } catch (_) {
      try {
        Process.killPid(pid, ProcessSignal.sigkill);
      } catch (_) {}
    }
  } else {
    try {
      Process.killPid(pid, ProcessSignal.sigkill);
    } catch (_) {}
  }

  if (kDebugMode) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<bool> _isProcessAlive(int pid) async {
  try {
    final result = await Process.run('kill', ['-0', '$pid']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}
