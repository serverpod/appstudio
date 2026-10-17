import 'dart:io';

import 'package:appstudio/runner/runner_postgres.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The Postgres a Windows runner stop leaves behind. Files only — no process
/// is started, signalled or stopped here.
void main() {
  late Directory serverDir;
  late String pgCtl;

  setUp(() async {
    serverDir = await Directory.systemTemp.createTemp('runner_postgres');
    final bin = Directory(p.join(serverDir.path, 'pg', 'bin'))
      ..createSync(recursive: true);
    pgCtl = p.join(bin.path, 'pg_ctl.exe');
    File(pgCtl).writeAsStringSync('');
    File(p.join(bin.path, 'postgres.exe')).writeAsStringSync('');
  });

  tearDown(() => serverDir.delete(recursive: true));

  String seedData(String mode, {int pid = 4242}) {
    final data = Directory(p.join(serverDir.path, '.serverpod', mode, 'pgdata'))
      ..createSync(recursive: true);
    File(p.join(data.path, 'postmaster.pid'))
        .writeAsStringSync('$pid\n${data.path}\n1760000000\n8090\n');
    final postgres = p.join(p.dirname(pgCtl), 'postgres.exe');
    File(p.join(data.path, 'postmaster.opts'))
        .writeAsStringSync('$postgres "-D" "${data.path}"\n');
    return data.path;
  }

  test('a Postgres still running after the stop gets a fast pg_ctl stop',
      () async {
    final data = seedData('development');
    final runs = <List<String>>[];

    await stopOrphanedPostgres(
      serverDir.path,
      isAlive: (pid) async => pid == 4242,
      run: (exe, args) async {
        runs.add([exe, ...args]);
        return ProcessResult(0, 0, '', '');
      },
      settle: Duration.zero,
    );

    expect(runs, [
      [pgCtl, 'stop', '-D', data, '-m', 'fast', '-w', '-t', '10'],
    ]);
  });

  test('one the runner stopped after all is left alone', () async {
    seedData('development');
    var checks = 0;
    final runs = <List<String>>[];

    await stopOrphanedPostgres(
      serverDir.path,
      // Gone on the second look.
      isAlive: (_) async => ++checks < 2,
      run: (exe, args) async {
        runs.add([exe, ...args]);
        return ProcessResult(0, 0, '', '');
      },
      settle: const Duration(seconds: 1),
      poll: const Duration(milliseconds: 1),
    );

    expect(runs, isEmpty);
  });

  test('an older template\'s data directory is found too', () async {
    final data = seedData('dev', pid: 7);
    final stopped = <String>[];

    await stopOrphanedPostgres(
      serverDir.path,
      isAlive: (_) async => true,
      run: (exe, args) async {
        stopped.add(args[2]);
        return ProcessResult(0, 0, '', '');
      },
      settle: Duration.zero,
    );

    expect(stopped, [data]);
  });

  test('a project without a database is a no-op', () async {
    final runs = <String>[];
    await stopOrphanedPostgres(
      serverDir.path,
      isAlive: (_) async => true,
      run: (exe, args) async {
        runs.add(exe);
        return ProcessResult(0, 0, '', '');
      },
      settle: Duration.zero,
    );
    expect(runs, isEmpty);
  });
}
