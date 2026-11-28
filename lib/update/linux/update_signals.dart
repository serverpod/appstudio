/// What the updater and its dialog tell each other, in a file of its own,
/// free of `dart:io`, so the dialog can use it.
library;

import 'dart:async';

/// Stops a download: at once, even while it waits on a server that has
/// stopped sending.
class UpdateCancellation {
  final _completer = Completer<void>();
  bool get isCancelled => _completer.isCompleted;

  /// Completes when [cancel] is called.
  Future<void> get whenCancelled => _completer.future;

  void cancel() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

/// The new AppImage is in place, but App Studio could not start it: there
/// is nothing to try again, only to start it by hand.
class UpdateInstalledException implements Exception {
  const UpdateInstalledException(this.version, this.message);

  /// The version now installed.
  final String version;
  final String message;

  @override
  String toString() => message;
}
