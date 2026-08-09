import 'package:flutter/foundation.dart';

/// Everything the toolbar's Full Restart button needs, and nothing that spawns
/// a process.
///
/// `ServerpodProcessController` implements this directly — no adapter — but the
/// button imports only this file. This button is now the only way to start or
/// stop the server, so its state rules are worth testing without a real
/// Serverpod runner behind them: a Full Restart that refuses to act while the
/// server is stopped would strand the user after any crash.
abstract interface class FullRestartView implements Listenable {
  /// False with no project open, and while a start or stop is already running.
  bool get canRestart;

  /// The server is coming up or going down. Distinct from [canRestart] so the
  /// button can show a spinner rather than just dimming.
  bool get isTransitioning;

  /// Nothing is running, so a restart is really a first start. Only affects the
  /// wording.
  bool get isStopped;

  Future<void> restart();
}
