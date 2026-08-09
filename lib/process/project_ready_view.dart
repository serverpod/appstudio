import 'package:flutter/foundation.dart';

/// Whether the open project is up: server compiled and running, Flutter app
/// attached, preview live.
///
/// `ServerpodProcessController` implements this directly. It exists so the two
/// things that wait on that moment — the Open in … buttons and the "your
/// project has started" notice — say what they mean, and can be tested without
/// a real Serverpod runner behind them.
abstract interface class ProjectReadyView implements Listenable {
  /// True only in `PreviewPhase.ready`. Everything earlier is still compiling,
  /// and an editor opened then would be looking at a project that cannot run.
  bool get projectIsReady;
}
