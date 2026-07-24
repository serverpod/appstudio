/// High-level stages while the preview comes up.
enum PreviewPhase {
  /// Project open but process not running.
  idle,

  /// `serverpod start` is launching.
  startingServerpod,

  /// Process running; waiting for :9998.
  waitingForServer,

  /// Port is up — CEF may load the Flutter web app.
  loadingApp,

  /// DWDS / VM service is attaching (reload imminent).
  connecting,

  /// Preview is live.
  ready,

  /// Shutting down.
  stopping,

  /// Start or runtime failure.
  failed,
}

extension PreviewPhaseX on PreviewPhase {
  /// Short, lightly entertaining copy for the phone overlay.
  String get overlayMessage => switch (this) {
        PreviewPhase.idle || PreviewPhase.stopping => 'Ready when you are',
        PreviewPhase.startingServerpod => 'Booting Serverpod',
        PreviewPhase.waitingForServer => 'Spinning up the server',
        PreviewPhase.loadingApp => 'Loading the app',
        PreviewPhase.connecting => 'Waking Flutter',
        PreviewPhase.ready => '',
        PreviewPhase.failed => 'Something went sideways',
      };

  bool get showsLoadingOverlay =>
      this != PreviewPhase.ready && this != PreviewPhase.failed;

  bool get isError => this == PreviewPhase.failed;

  /// Idle / stopping — show bored Nova instead of the running loop.
  bool get isStopped =>
      this == PreviewPhase.idle || this == PreviewPhase.stopping;
}
