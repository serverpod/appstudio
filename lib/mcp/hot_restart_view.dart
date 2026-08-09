import 'package:flutter/foundation.dart';

/// How far along the connection to `serverpod mcp-server` is.
///
/// The distinction between [connecting] and [connected] is the whole point: the
/// bridge process starts and answers happily with no `serverpod start` behind
/// it, so "the bridge is up" says nothing about whether a hot restart can
/// actually be delivered.
enum McpConnection {
  /// No project open, or no server running — there is nothing to connect to.
  idle,

  /// The bridge is coming up, or it is up and waiting for a runner to appear.
  connecting,

  /// A live `serverpod start` is on the other end.
  connected,

  /// The bridge could not be started or has stopped. See
  /// [HotRestartView.hotRestartError].
  unavailable,
}

/// Everything the toolbar's hot-restart button needs, and nothing that spawns
/// a process or touches the disk.
///
/// `McpController` implements this directly — no adapter — but the toolbar
/// imports only this file, which keeps the button testable without a real
/// Serverpod runner behind it.
abstract interface class HotRestartView implements Listenable {
  McpConnection get mcpConnection;

  /// True while a hot restart is in flight. It covers a full recompile and a
  /// process reboot, so this is seconds, not milliseconds.
  bool get isHotRestarting;

  /// Why the last attempt failed, or why there is no connection. Null when
  /// there is nothing to report.
  String? get hotRestartError;

  /// Recompiles and reboots the server, then hot-restarts the Flutter app.
  ///
  /// Does nothing unless [mcpConnection] is [McpConnection.connected].
  Future<void> hotRestart();
}
