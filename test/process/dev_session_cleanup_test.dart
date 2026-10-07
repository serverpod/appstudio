import 'dart:io';

import 'package:appstudio/process/dev_session_cleanup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    for (final kind in DevProcessKind.values) {
      await clearDevSessionPid(kind);
    }
  });

  test('the agent is registered, and the runner is not', () {
    // The Serverpod runner is detached by design and is stopped through its
    // socket from an ownership record, not by a pid file and a group kill.
    expect(DevProcessKind.values.map((k) => k.id), ['agent']);
    expect(DevProcessKind.agent.pidFile, endsWith('appstudio-agent.pid'));
  });

  test('register writes the pid and clear removes the file', () async {
    final file = File(DevProcessKind.agent.pidFile);

    await registerDevSessionPid(DevProcessKind.agent, 424242);
    expect(await file.exists(), isTrue);
    expect((await file.readAsString()).trim(), '424242');

    await clearDevSessionPid(DevProcessKind.agent);
    expect(await file.exists(), isFalse);
  });

  test('a nonsense pid is not written', () async {
    await registerDevSessionPid(DevProcessKind.agent, 0);
    await registerDevSessionPid(DevProcessKind.agent, -1);

    expect(await File(DevProcessKind.agent.pidFile).exists(), isFalse);
  });

  test('reclaim consumes the pid file even when the process is long gone',
      () async {
    // The reclaim must be self-clearing. A file left behind would make every
    // later launch try to kill a pid that has since been recycled by the OS —
    // which is how a reclaim turns into killing an unrelated process.
    await registerDevSessionPid(DevProcessKind.agent, 999999);

    await reclaimRegisteredPids();

    expect(await File(DevProcessKind.agent.pidFile).exists(), isFalse);
  });

  test('reclaims a plain child, which leads no process group', () async {
    // The regression that let `opencode serve` survive every launch: a
    // `Process.start` child inherits our process group and leads none of its
    // own, so a group-only kill (`-pid`) matched nothing. `Process.killPid`
    // reports that with `false` rather than an exception, so the catch-driven
    // fallback to the single pid never ran and the child lived on.
    final child = await Process.start('/bin/sleep', ['300']);
    addTearDown(() => child.kill(ProcessSignal.sigkill));
    await registerDevSessionPid(DevProcessKind.agent, child.pid);

    await reclaimRegisteredPids();

    // Completes only once the process is really reaped.
    await expectLater(
      child.exitCode.timeout(const Duration(seconds: 5)),
      completes,
    );
  });
}
