import 'tool_status.dart';

enum ToolPhase {
  queued,

  /// Apple's Command Line Tools installer is up; it reports nothing back, so
  /// all we can do is wait for the tools to appear.
  waitingForApple,
  downloading,
  verifying,
  extracting,

  /// `flutter precache --web` and the `PATH` line.
  configuring,

  /// `flutter upgrade` on a copy App Studio installed.
  upgrading,

  /// `dart install serverpod_cli`.
  installing,
  done,
  failed,
  cancelled;

  bool get isTerminal =>
      this == done || this == failed || this == cancelled;

  String get label => switch (this) {
        queued => 'Waiting for',
        waitingForApple => 'Installing',
        downloading => 'Downloading',
        verifying => 'Verifying',
        extracting => 'Unpacking',
        configuring => 'Setting up',
        upgrading => 'Updating',
        installing => 'Installing',
        done => 'Installed',
        failed => 'Failed',
        cancelled => 'Cancelled',
      };

  /// What is actually happening, for the line under the bar. Null for the
  /// download, which shows its byte count instead.
  String? get hint => switch (this) {
        waitingForApple =>
          'Follow the steps in the window Apple opened. This can take several '
              'minutes.',
        verifying || extracting => 'This takes a minute.',
        configuring => 'Fetching the web components with flutter precache.',
        upgrading => 'Running flutter upgrade.',
        installing => 'Running dart install serverpod_cli.',
        _ => null,
      };
}

class ToolProgress {
  const ToolProgress({
    required this.id,
    required this.phase,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.phaseStartedAt,
    this.error,
  });

  final ToolId id;
  final ToolPhase phase;
  final int receivedBytes;
  final int totalBytes;

  /// When [phase] began — the download's ETA is measured from it.
  final DateTime? phaseStartedAt;
  final String? error;

  /// 0..1 through the current phase, or null when there is nothing to measure
  /// — every step but the download.
  double? get fraction {
    if (phase == ToolPhase.done) return 1;
    if (phase != ToolPhase.downloading || totalBytes <= 0) return null;
    return (receivedBytes / totalBytes).clamp(0.0, 1.0);
  }

  ToolProgress copyWith({
    ToolPhase? phase,
    int? receivedBytes,
    int? totalBytes,
    DateTime? phaseStartedAt,
    String? error,
  }) {
    return ToolProgress(
      id: id,
      phase: phase ?? this.phase,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      phaseStartedAt: phaseStartedAt ?? this.phaseStartedAt,
      error: error ?? this.error,
    );
  }
}

/// A run over several tools, one after the other.
///
/// Reported per step rather than as one bar over the whole run: only the
/// Flutter download can measure itself, and a single bar weighted across Apple's
/// installer, a 2 GB download and a `dart install` would sit still or leap.
class InstallProgress {
  InstallProgress({required this.tools, required this.startedAt, this.now});

  final List<ToolProgress> tools;
  final DateTime startedAt;

  /// Injected in tests; wall-clock otherwise.
  final DateTime? now;

  bool get isDone => tools.every((t) => t.phase.isTerminal);
  bool get hasFailure => tools.any((t) => t.phase == ToolPhase.failed);

  /// The step in progress, or null once every step has finished.
  ToolProgress? get current {
    for (final tool in tools) {
      if (!tool.phase.isTerminal) return tool;
    }
    return null;
  }

  /// "Step 2 of 3" — null for a run of one.
  String? get stepLabel {
    if (tools.length < 2) return null;
    final at = current;
    if (at == null) return null;
    return 'Step ${tools.indexOf(at) + 1} of ${tools.length}';
  }

  /// The line above the bar: what is happening to which tool.
  ///
  /// Once every step is terminal there is still work in flight — the re-probe
  /// — so this keeps naming a step rather than falling back to "Installed" and
  /// the last tool, which read as finished while the dialog was visibly still
  /// busy.
  String get statusLabel {
    final at = current;
    if (at == null) return 'Finishing up…';
    return '${at.phase.label} ${at.id.displayName}…';
  }

  /// Explanation for the current step, when it is not a download.
  String? get hint => current?.phase.hint;

  bool get isDownloading => current?.phase == ToolPhase.downloading;

  /// The bar: the current step's own progress, or null (indeterminate).
  double? get fraction => isDone ? 1 : current?.fraction;

  int get bytesReceived => isDownloading ? current!.receivedBytes : 0;
  int get bytesTotal => isDownloading ? current!.totalBytes : 0;

  /// For the download only. Null until there is enough signal to be worth
  /// showing.
  Duration? get eta {
    final at = current;
    final started = at?.phaseStartedAt;
    final done = at?.fraction;
    if (at == null || started == null || done == null) return null;
    final elapsed = (now ?? DateTime.now()).difference(started);
    if (elapsed.inSeconds < 3 || done <= 0.01 || done >= 1) return null;
    final remaining = elapsed.inMilliseconds / done - elapsed.inMilliseconds;
    if (remaining <= 0) return null;
    return Duration(milliseconds: remaining.round());
  }

  ToolProgress? operator [](ToolId id) {
    for (final tool in tools) {
      if (tool.id == id) return tool;
    }
    return null;
  }
}
