import 'tool_status.dart';

enum ToolPhase {
  queued,
  preflight,
  downloading,
  verifying,
  extracting,
  finalizing,
  done,
  failed,
  cancelled;

  bool get isTerminal =>
      this == done || this == failed || this == cancelled;

  String get label => switch (this) {
        queued => 'Waiting',
        preflight => 'Checking disk space',
        downloading => 'Downloading',
        verifying => 'Verifying',
        extracting => 'Extracting',
        finalizing => 'Finishing up',
        done => 'Installed',
        failed => 'Failed',
        cancelled => 'Cancelled',
      };
}

/// Rough share of wall-clock each phase takes, so the overall bar does not
/// stall at 100 % through a minute of extraction.
const _phaseWeights = <ToolPhase, double>{
  ToolPhase.downloading: 0.85,
  ToolPhase.verifying: 0.05,
  ToolPhase.extracting: 0.10,
};

class ToolProgress {
  const ToolProgress({
    required this.id,
    required this.phase,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.error,
  });

  final ToolId id;
  final ToolPhase phase;
  final int receivedBytes;
  final int totalBytes;
  final String? error;

  /// 0..1 of this tool's whole install, or null when indeterminate.
  double? get fraction {
    switch (phase) {
      case ToolPhase.done:
        return 1;
      case ToolPhase.queued:
      case ToolPhase.preflight:
        return 0;
      case ToolPhase.failed:
      case ToolPhase.cancelled:
        return null;
      case ToolPhase.downloading:
        if (totalBytes <= 0) return null;
        final ratio = (receivedBytes / totalBytes).clamp(0.0, 1.0);
        return ratio * _phaseWeights[ToolPhase.downloading]!;
      case ToolPhase.verifying:
        return _phaseWeights[ToolPhase.downloading]!;
      case ToolPhase.extracting:
      case ToolPhase.finalizing:
        return _phaseWeights[ToolPhase.downloading]! +
            _phaseWeights[ToolPhase.verifying]!;
    }
  }

  ToolProgress copyWith({
    ToolPhase? phase,
    int? receivedBytes,
    int? totalBytes,
    String? error,
  }) {
    return ToolProgress(
      id: id,
      phase: phase ?? this.phase,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      error: error ?? this.error,
    );
  }
}

class InstallProgress {
  InstallProgress({required this.tools, required this.startedAt, this.now});

  final List<ToolProgress> tools;
  final DateTime startedAt;

  /// Injected in tests; wall-clock otherwise.
  final DateTime? now;

  bool get isDone => tools.every((t) => t.phase.isTerminal);
  bool get hasFailure => tools.any((t) => t.phase == ToolPhase.failed);

  /// The line above the bar: what is happening to which tool.
  ///
  /// Once every tool is terminal there is still work in flight — the re-probe,
  /// and the shell PATH write the setup dialog adds — so this keeps naming a
  /// step rather than falling back to `Installed <the last tool>`, which read
  /// as finished while the dialog was visibly still busy.
  String get statusLabel {
    for (final tool in tools) {
      if (!tool.phase.isTerminal) {
        return '${tool.phase.label} ${tool.id.displayName}…';
      }
    }
    return 'Finishing up…';
  }

  int get bytesReceived =>
      tools.fold(0, (sum, t) => sum + t.receivedBytes);

  int get bytesTotal => tools.fold(0, (sum, t) => sum + t.totalBytes);

  /// Weighted by each tool's download size, so a 673 MB Flutter does not
  /// advance the bar at the same rate as an 11 MB CLI.
  double get fraction {
    if (tools.isEmpty) return 0;
    var weight = 0.0;
    var progress = 0.0;
    for (final tool in tools) {
      final toolWeight = tool.totalBytes > 0 ? tool.totalBytes.toDouble() : 1.0;
      weight += toolWeight;
      progress += toolWeight * (tool.fraction ?? 0);
    }
    return weight == 0 ? 0 : (progress / weight).clamp(0.0, 1.0);
  }

  /// Null until there is enough signal to be worth showing.
  Duration? get eta {
    final elapsed = (now ?? DateTime.now()).difference(startedAt);
    if (elapsed.inSeconds < 3) return null;
    final done = fraction;
    if (done <= 0.01 || done >= 1) return null;
    final total = elapsed.inMilliseconds / done;
    final remaining = total - elapsed.inMilliseconds;
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
