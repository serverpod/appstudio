import 'package:appstudio/agent/agent_controller.dart';
import 'package:appstudio/process/serverpod_process.dart';
import 'package:appstudio/session/project_session.dart';
import 'package:appstudio/terminal/studio_terminal.dart';
import 'package:appstudio/update/update_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/toolchain_support.dart';

/// The updater must never be able to break the app. Everything here is about
/// the failure paths: no Swift side at all, a Swift side that errors, and the
/// relaunch handshake that Sparkle blocks on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(UpdateController.kUpdateChannel);

  late List<MethodCall> calls;
  late ServerpodProcessController process;
  late AgentController agent;

  /// Installs a fake Swift side. [replies] is keyed by method name; a value of
  /// `_throws` makes that method fail.
  void mockChannel(Map<String, Object?> replies) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      final reply = replies[call.method];
      if (reply == _throws) {
        throw PlatformException(code: 'unavailable', message: 'nope');
      }
      return reply;
    });
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    calls = [];
    final toolchains = await emptyToolchainController();
    final session = ProjectSession();
    process = ServerpodProcessController(
      toolchains: toolchains,
      session: session,
      terminal: StudioTerminal(),
    );
    agent = AgentController(
      toolchains: toolchains,
      session: session,
      process: process,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<UpdateController> create() =>
      UpdateController.create(process: process, agent: agent);

  test('create() succeeds when there is no platform side at all', () async {
    // No mock installed, so every invoke throws MissingPluginException. This is
    // what a widget test, or a future non-macOS build, looks like — and it runs
    // inside main(), before any UI exists to report a failure.
    final controller = await create();
    addTearDown(controller.dispose);

    expect(controller.state.configured, isFalse);
    expect(controller.state.canCheck, isFalse);
  });

  test('create() survives a platform side that throws', () async {
    mockChannel({'getState': _throws});
    final controller = await create();
    addTearDown(controller.dispose);

    expect(controller.state.configured, isFalse);
  });

  test('reads state from the platform', () async {
    mockChannel({
      'getState': {
        'configured': true,
        'currentVersion': '0.0.1',
        'currentBuild': '1',
        'automaticallyChecks': true,
      },
    });
    final controller = await create();
    addTearDown(controller.dispose);

    expect(controller.state.configured, isTrue);
    expect(controller.state.canCheck, isTrue);
    expect(controller.state.versionLabel, 'Version 0.0.1 (build 1)');
  });

  test('an unconfigured build cannot check', () async {
    mockChannel({
      'getState': {
        'configured': false,
        'error': 'This build has no update feed.',
      },
    });
    final controller = await create();
    addTearDown(controller.dispose);

    expect(controller.state.canCheck, isFalse);
    expect(controller.state.error, isNotNull);
  });

  test('checkForUpdates reaches the platform and refreshes', () async {
    mockChannel({
      'getState': {'configured': true},
      'checkForUpdates': null,
    });
    final controller = await create();
    addTearDown(controller.dispose);
    calls.clear();

    await controller.checkForUpdates();

    expect(calls.map((c) => c.method), ['checkForUpdates', 'getState']);
  });

  test('checkForUpdates does not throw when the platform rejects it', () async {
    mockChannel({
      'getState': {'configured': true},
      'checkForUpdates': _throws,
    });
    final controller = await create();
    addTearDown(controller.dispose);

    await expectLater(controller.checkForUpdates(), completes);
  });

  test('setAutomaticallyChecks updates optimistically', () async {
    mockChannel({
      'getState': {'configured': true, 'automaticallyChecks': true},
      'setAutomaticallyChecks': null,
    });
    final controller = await create();
    addTearDown(controller.dispose);

    var notifications = 0;
    controller.addListener(() => notifications++);

    // The switch should move on tap, not after a round trip.
    final pending = controller.setAutomaticallyChecks(false);
    expect(controller.state.automaticallyChecks, isFalse);
    expect(notifications, 1);
    await pending;

    expect(
      calls.where((c) => c.method == 'setAutomaticallyChecks').single.arguments,
      {'enabled': false},
    );
  });

  test('pushes session busy state so Swift never has to ask', () async {
    // Sparkle asks its delegate synchronously on the main thread. If Dart had
    // to answer on demand, the answer would have to come from the thread that
    // is blocked waiting for it.
    mockChannel({
      'getState': {'configured': true},
      'setSessionBusy': null,
    });
    final controller = await create();
    addTearDown(controller.dispose);

    // Nothing is running, so the initial push is "not busy" — or nothing at
    // all, since false is the assumed starting state.
    final busyCalls = calls.where((c) => c.method == 'setSessionBusy');
    for (final call in busyCalls) {
      expect((call.arguments as Map)['busy'], isFalse);
    }
  });

  test('prepareForRelaunch always completes, so Sparkle is never stuck',
      () async {
    mockChannel({'getState': {'configured': true}});
    final controller = await create();
    addTearDown(controller.dispose);

    // Nothing is running here, so teardown is a no-op — the point is that it
    // returns rather than hanging Sparkle's install.
    await expectLater(
      controller.prepareForRelaunch().timeout(const Duration(seconds: 20)),
      completes,
    );
  });

  test('a prepareForRelaunch call from Swift is answered', () async {
    mockChannel({'getState': {'configured': true}});
    final controller = await create();
    addTearDown(controller.dispose);

    // Simulate Swift invoking the method on us.
    final codec = const StandardMethodCodec();
    final reply = await TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .handlePlatformMessage(
      UpdateController.kUpdateChannel,
      codec.encodeMethodCall(const MethodCall('prepareForRelaunch')),
      (_) {},
    );

    expect(reply, isNotNull, reason: 'Sparkle blocks until this returns');
  });

  test('dispose stops listening to the session', () async {
    mockChannel({
      'getState': {'configured': true},
      'setSessionBusy': null,
    });
    final controller = await create();
    controller.dispose();
    calls.clear();

    // A late notification from a controller that outlives us must not fire a
    // channel call against a disposed object.
    process.notifyListeners();
    await Future<void>.delayed(Duration.zero);

    expect(calls, isEmpty);
  });
}

/// Sentinel telling the mock handler to throw for that method.
const _throws = Object();
