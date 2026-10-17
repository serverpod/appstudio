import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../agent/agent_controller.dart';
import '../platform/afunix_settle.dart';
import '../process/serverpod_process.dart';
import 'session_teardown.dart';
import 'update_state.dart';

/// Dart's half of the Sparkle bridge (`macos/Runner/SparkleUpdater.swift`).
///
/// Sparkle owns the update UI, so this class is small on purpose. It does
/// three things:
///
///  * exposes [state] for the menu item and the settings pane;
///  * keeps Swift told whether a session is live, so scheduled checks can be
///    vetoed without Swift having to call back into a possibly-busy engine;
///  * runs the teardown when Sparkle is about to relaunch.
///
/// Every channel call is guarded. An updater that throws during startup, or on
/// a machine where the channel is absent (tests, a non-macOS host), must leave
/// the app fully usable — nobody should lose their IDE because the updater is
/// unhappy.
class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.process,
    required this.agent,
    @visibleForTesting MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel(kUpdateChannel);

  /// Matches `SparkleUpdater.channelName`.
  static const kUpdateChannel = 'dev.serverpod.appstudio/updates';

  final ServerpodProcessController process;
  final AgentController agent;
  final MethodChannel _channel;

  UpdateState _state = UpdateState.unavailable;
  UpdateState get state => _state;

  bool _disposed = false;
  bool _sessionBusy = false;

  /// Never throws. A failure here yields an [UpdateState] that reports itself
  /// unavailable, which the UI already knows how to render.
  static Future<UpdateController> create({
    required ServerpodProcessController process,
    required AgentController agent,
    @visibleForTesting MethodChannel? channel,
  }) async {
    final controller = UpdateController(
      process: process,
      agent: agent,
      channel: channel,
    );
    controller._channel.setMethodCallHandler(controller._handleCall);
    await controller.refresh();
    controller._watchSession();
    // Why the menu item is enabled or greyed out is otherwise invisible — the
    // user just sees a dead menu entry with no way to find out.
    final state = controller.state;
    debugPrint(
      'UpdateController: configured=${state.configured} '
      'canCheck=${state.canCheck} translocated=${state.translocated} '
      'auto=${state.automaticallyChecks} '
      '${state.versionLabel}${state.error == null ? '' : ' error=${state.error}'}',
    );
    return controller;
  }

  Future<void> refresh() async {
    final next = await _guard<UpdateState>(
      'getState',
      () async {
        final reply =
            await _channel.invokeMapMethod<Object?, Object?>('getState');
        return reply == null ? UpdateState.unavailable : UpdateState.fromMap(reply);
      },
      fallback: UpdateState.unavailable,
    );
    if (_disposed || next == _state) return;
    _state = next;
    notifyListeners();
  }

  /// Shows Sparkle's UI. Always the user-initiated path, so it reports "you're
  /// up to date" rather than silently doing nothing.
  Future<void> checkForUpdates() async {
    await _guard<void>('checkForUpdates', () async {
      await _channel.invokeMethod<void>('checkForUpdates');
    });
    await refresh();
  }

  Future<void> setAutomaticallyChecks(bool enabled) async {
    // Optimistic: the switch should not lag behind the tap. refresh() below
    // corrects it if Swift disagreed.
    if (_state.automaticallyChecks != enabled) {
      _state = _state.copyWith(automaticallyChecks: enabled);
      notifyListeners();
    }
    await _guard<void>('setAutomaticallyChecks', () async {
      await _channel.invokeMethod<void>(
        'setAutomaticallyChecks',
        {'enabled': enabled},
      );
    });
    await refresh();
  }

  // MARK: - Session state

  /// Pushes busy-ness to Swift whenever it changes.
  ///
  /// Push rather than pull because Sparkle asks its delegate synchronously on
  /// the main thread; asking Dart at that moment and waiting for an answer
  /// would deadlock the thread that has to produce it.
  void _watchSession() {
    process.addListener(_syncSessionBusy);
    agent.addListener(_syncSessionBusy);
    _syncSessionBusy();
  }

  void _syncSessionBusy() {
    final busy = process.canStop || agent.isServeRunning;
    if (busy == _sessionBusy) return;
    _sessionBusy = busy;
    unawaited(
      _guard<void>('setSessionBusy', () async {
        await _channel.invokeMethod<void>('setSessionBusy', {'busy': busy});
      }),
    );
  }

  // MARK: - Swift -> Dart

  Future<Object?> _handleCall(MethodCall call) async {
    switch (call.method) {
      case 'prepareForRelaunch':
        await prepareForRelaunch();
        return true;
      default:
        return null;
    }
  }

  /// Sparkle is holding the relaunch open until this returns. Whatever happens,
  /// return — Swift also has its own timeout, but relying on it would mean an
  /// avoidable 20-second stall on every update.
  @visibleForTesting
  Future<void> prepareForRelaunch() async {
    try {
      await teardownSession(process: process, agent: agent);
    } catch (e) {
      debugPrint('UpdateController: teardown before relaunch failed: $e');
    }
    // The process ends right after this returns: on Windows, let the kernel
    // finish closing the runner connection first (afunix.sys).
    await settleAfUnixSockets();
  }

  Future<T> _guard<T>(
    String what,
    Future<T> Function() action, {
    T? fallback,
  }) async {
    try {
      return await action();
    } on MissingPluginException {
      // No Swift side at all — a test, or a platform we do not ship on.
      return fallback as T;
    } catch (e) {
      debugPrint('UpdateController: $what failed: $e');
      return fallback as T;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    process.removeListener(_syncSessionBusy);
    agent.removeListener(_syncSessionBusy);
    super.dispose();
  }
}
