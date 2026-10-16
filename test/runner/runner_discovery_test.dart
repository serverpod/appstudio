import 'dart:io';

import 'package:appstudio/platform/host_platform.dart';
import 'package:appstudio/runner/runner_discovery.dart';
import 'package:appstudio/runner/runner_ownership.dart';
import 'package:appstudio/runner/runner_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fake_runner.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('appstudio_discovery');
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<void> package(String relative, String pubspec) async {
    final dir = Directory(p.join(root.path, relative));
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'pubspec.yaml')).writeAsString(pubspec);
  }

  group('findServerDirectory', () {
    test('finds the server package beside the client and the app', () async {
      await package('demo_server', 'name: demo_server\ndependencies:\n'
          '  serverpod: 4.1.0\n');
      await package('demo_client', 'name: demo_client\ndependencies:\n'
          '  serverpod_client: 4.1.0\n');
      await package('demo_flutter', 'name: demo_flutter\ndependencies:\n'
          '  flutter:\n    sdk: flutter\n  demo_client:\n    path: ../\n');

      expect(
        await findServerDirectory(root.path),
        p.join(root.path, 'demo_server'),
      );
    });

    test('is the folder itself when that is the server', () async {
      await package('.', 'name: demo_server\ndependencies:\n  serverpod: any\n');

      expect(await findServerDirectory(root.path), p.normalize(root.path));
    });

    test('ignores a dev dependency and a commented-out one', () async {
      await package(
        'tool',
        'name: tool\n'
            'dependencies:\n'
            '#  serverpod: any\n'
            'dev_dependencies:\n'
            '  serverpod: any\n',
      );

      expect(await findServerDirectory(root.path), isNull);
    });

    test('refuses a folder with two servers', () async {
      await package('a_server', 'name: a\ndependencies:\n  serverpod: any\n');
      await package('b_server', 'name: b\ndependencies:\n  serverpod: any\n');

      expect(
        () => findServerDirectory(root.path),
        throwsA(isA<RunnerDiscoveryException>()),
      );
    });
  });

  group('runnerSocketPath', () {
    test('uses the package path when it fits', () {
      expect(
        runnerSocketPath(
          '/tmp/x_server',
          projectId: 'id',
          host: HostPlatform.macos,
        ),
        '/tmp/x_server/.dart_tool/serverpod/tui.sock',
      );
    });

    test('falls back to the registry link when the package path is too long',
        () {
      final deep = '/Users/someone/${'nested/' * 12}demo_server';

      expect(
        runnerSocketPath(
          deep,
          projectId: 'cafb635d',
          environment: {'HOME': '/Users/someone'},
          host: HostPlatform.macos,
        ),
        '/Users/someone/.serverpod/runners/cafb635d/tui.sock',
      );
    });

    test('honours the registry override the CLI honours', () {
      final deep = '/x/${'nested/' * 14}demo_server';
      expect(
        runnerSocketPath(
          deep,
          projectId: 'id',
          environment: {'SERVERPOD_RUNNER_REGISTRY_DIR': '/r'},
          host: HostPlatform.macos,
        ),
        '/r/id/tui.sock',
      );
    });
  });

  group('runnerSocketPath on Windows', () {
    test('reads the home directory from USERPROFILE', () {
      expect(
        runnerRegistryDir(
          environment: {'USERPROFILE': r'C:\Users\alex'},
          host: HostPlatform.windows,
        ),
        r'C:\Users\alex\.serverpod\runners',
      );
    });

    test('allows the 108-byte address Windows and Linux allow', () {
      expect(maxUnixSocketPathBytes(HostPlatform.windows), 108);
      expect(maxUnixSocketPathBytes(HostPlatform.macos), 104);
    });

    test('falls back to the registry link for a deep package', () {
      final deep = r'C:\Users\alex' + r'\nested' * 12 + r'\demo_server';
      expect(
        runnerSocketPath(
          deep,
          projectId: 'cafb635d',
          environment: {'USERPROFILE': r'C:\Users\alex'},
          host: HostPlatform.windows,
        ),
        r'C:\Users\alex\.serverpod\runners\cafb635d\tui.sock',
      );
    });
  });

  // Fake runners serve AF_UNIX sockets: see `dart_test.yaml` on `process`.
  group('resolveRunner', () {
    test('no manifest is no runner', () async {
      expect(await resolveRunner(root.path), isA<NoRunner>());
    });

    test('a live runner, then the manifest it leaves behind', () async {
      final project = await FakeRunner.createProject();
      final serverDir = FakeRunner.serverDirOf(project);
      final runner = await FakeRunner.start(serverDir);
      addTearDown(() => project.delete(recursive: true));

      final live = await resolveRunner(serverDir);
      expect(live, isA<LiveRunner>());
      expect((live as LiveRunner).manifest.pid, runner.pid);

      await runner.stopRunner(exitCode: 3);
      final gone = await resolveRunner(serverDir);
      expect(gone, isA<NoRunner>());
      expect((gone as NoRunner).staleManifest?.exitCode, 3);
      expect(gone.staleManifest?.isFinished, isTrue);
    }, tags: 'process');

    test('a runner speaking another protocol is refused', () async {
      final project = await FakeRunner.createProject();
      final serverDir = FakeRunner.serverDirOf(project);
      final runner = await FakeRunner.start(serverDir, protocolVersion: 2);
      addTearDown(() async {
        await runner.close();
        await project.delete(recursive: true);
      });

      expect(await resolveRunner(serverDir), isA<IncompatibleRunner>());
    }, tags: 'process');
  });

  // Fake runners serve AF_UNIX sockets: see `dart_test.yaml` on `process`.
  group('reclaimOwnedRunner', () {
    setUp(() {
      ownedRunnerRecordPathOverride = p.join(root.path, 'owned.json');
    });

    tearDown(() => ownedRunnerRecordPathOverride = null);

    test('stops the runner a previous run started, over its socket', () async {
      final project = await FakeRunner.createProject();
      final serverDir = FakeRunner.serverDirOf(project);
      final runner = await FakeRunner.start(serverDir, pid: FakeRunner.fakePid(777));
      addTearDown(() => project.delete(recursive: true));
      await recordOwnedRunner(OwnedRunner(serverDir: serverDir, pid: FakeRunner.fakePid(777)));

      await reclaimOwnedRunner();

      expect(runner.calls, contains('stop'));
      expect(await readOwnedRunner(), isNull);
    }, tags: 'process');

    test('leaves alone a runner that has another pid now', () async {
      final project = await FakeRunner.createProject();
      final serverDir = FakeRunner.serverDirOf(project);
      final runner = await FakeRunner.start(serverDir, pid: FakeRunner.fakePid(778));
      addTearDown(() async {
        await runner.close();
        await project.delete(recursive: true);
      });
      await recordOwnedRunner(OwnedRunner(serverDir: serverDir, pid: FakeRunner.fakePid(1)));

      await reclaimOwnedRunner();

      expect(runner.calls, isNot(contains('stop')));
      // Consumed either way: a stale record must not linger into a later pid.
      expect(await readOwnedRunner(), isNull);
    }, tags: 'process');
  });

  test('the protocol version matches the CLI this was built against', () {
    expect(kRunnerProtocolVersion, 1);
  });
}
