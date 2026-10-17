import 'dart:io';

import 'package:path/path.dart' as p;

/// Windows only: stops the project's own Postgres when the runner App Studio
/// just stopped left it running.
///
/// On Windows the Serverpod 4.1 CLI's runner stop ends the runner, its Dart
/// processes and the Flutter web server, but the bundled Postgres it started
/// (`postgres.exe` from the CLI's `pg-binaries` cache, on the server's
/// `.serverpod\development\pgdata`) keeps running with nobody left to stop it
/// (Phase 0,
/// specs/windows_port.md; reported to Serverpod). This waits [settle] for the
/// runner to have done it after all, then asks that Postgres's own `pg_ctl`
/// for a fast shutdown — a graceful stop over Postgres's signal pipe, not a
/// kill.
///
/// Only ever for a runner App Studio itself stopped: a runner someone else
/// owns may still be using its database. Best effort; never throws.
Future<void> stopOrphanedPostgres(
  String serverDir, {
  required Future<bool> Function(int pid) isAlive,
  Future<ProcessResult> Function(String executable, List<String> arguments)?
      run,
  Duration settle = const Duration(seconds: 3),
  Duration poll = const Duration(milliseconds: 250),
}) async {
  final runner = run ?? (exe, args) => Process.run(exe, args);
  try {
    for (final dataDir in await _dataDirectories(serverDir)) {
      final pid = await _postmasterPid(dataDir);
      if (pid == null) continue;
      final waited = Stopwatch()..start();
      var alive = await isAlive(pid);
      while (alive && waited.elapsed < settle) {
        await Future<void>.delayed(poll);
        alive = await isAlive(pid);
      }
      if (!alive) continue;
      final pgCtl = await _pgCtlFor(dataDir);
      if (pgCtl == null) continue;
      await runner(pgCtl, ['stop', '-D', dataDir, '-m', 'fast', '-w', '-t', '10']);
    }
  } catch (_) {
    // A Postgres left running is what happened before this existed.
  }
}

/// `<server>\.serverpod\<mode>\pgdata` for every mode a runner has used —
/// `development` in today's template, `dev` in older ones.
Future<List<String>> _dataDirectories(String serverDir) async {
  final root = Directory(p.join(serverDir, '.serverpod'));
  if (!await root.exists()) return const [];
  final found = <String>[];
  await for (final mode in root.list()) {
    if (mode is! Directory) continue;
    final data = p.join(mode.path, 'pgdata');
    if (await File(p.join(data, 'postmaster.pid')).exists()) found.add(data);
  }
  return found;
}

/// The first line of `postmaster.pid` is the postmaster's pid.
Future<int?> _postmasterPid(String dataDir) async {
  try {
    final lines =
        await File(p.join(dataDir, 'postmaster.pid')).readAsLines();
    return lines.isEmpty ? null : int.tryParse(lines.first.trim());
  } on FileSystemException {
    return null;
  }
}

/// `pg_ctl` beside the `postgres` that is running, which `postmaster.opts`
/// names: `C:/…/bin/postgres.exe "-D" "…"`. The same binaries, so the same
/// version, whatever the CLI's cache holds.
Future<String?> _pgCtlFor(String dataDir) async {
  try {
    final opts =
        await File(p.join(dataDir, 'postmaster.opts')).readAsString();
    final match = RegExp(r'^"?(.+?postgres(?:\.exe)?)"?(?:\s|$)',
            caseSensitive: false)
        .firstMatch(opts.trim());
    final postgres = match?.group(1);
    if (postgres == null) return null;
    final pgCtl = p.join(
      p.dirname(postgres),
      postgres.toLowerCase().endsWith('.exe') ? 'pg_ctl.exe' : 'pg_ctl',
    );
    return await File(pgCtl).exists() ? pgCtl : null;
  } on FileSystemException {
    return null;
  }
}
