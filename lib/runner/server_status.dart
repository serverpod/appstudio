import 'package:flutter/foundation.dart';

/// What the toolbar's status says about the server.
enum ServerStatusKind {
  /// Up and serving — a green dot.
  running,

  /// Not running, on purpose or not — a red square.
  stopped,

  /// Coming up, going down, or doing something — a spinner.
  busy,
}

/// The server's state in one line, for the toolbar.
@immutable
class ServerStatus {
  const ServerStatus.running([this.message = 'Running'])
      : kind = ServerStatusKind.running,
        detail = null,
        settlesIn = null;

  const ServerStatus.stopped(this.message, {this.detail})
      : kind = ServerStatusKind.stopped,
        settlesIn = null;

  const ServerStatus.busy(this.message, {this.settlesIn})
      : kind = ServerStatusKind.busy,
        detail = null;

  final ServerStatusKind kind;

  /// The line shown: the state, or — while busy — the latest thing the runner
  /// is doing.
  final String message;

  /// More than fits on the line, such as the whole error. For the tooltip.
  final String? detail;

  /// When to look again although nothing has notified: an operation too young
  /// to show yet (see `kStatusOperationDelay`) becomes old enough to.
  final Duration? settlesIn;

  @override
  bool operator ==(Object other) =>
      other is ServerStatus &&
      other.kind == kind &&
      other.message == message &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(kind, message, detail);
}

/// How long an operation must run before the status shows it.
///
/// The pod reports every non-internal log scope as an operation — an endpoint
/// call included — and those last milliseconds. Shown at once, a busy server
/// would flicker a spinner on every request.
const kStatusOperationDelay = Duration(milliseconds: 400);

/// Everything the toolbar's status needs. `ServerpodProcessController`
/// provides one; Widgetbook fakes it.
abstract interface class ServerStatusView implements Listenable {
  ServerStatus get serverStatus;
}
