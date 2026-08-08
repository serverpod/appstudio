import 'toolchain_manifest.dart';
import 'tool_version.dart';

enum ToolId {
  flutter('flutter', 'Flutter SDK'),
  serverpodCli('serverpod_cli', 'Serverpod CLI'),
  opencode('opencode', 'OpenCode'),
  git('git', 'Git'),
  llvmTools('llvm-tools', 'Native tools');

  const ToolId(this.manifestId, this.displayName);

  final String manifestId;
  final String displayName;

  static ToolId? fromManifestId(String id) {
    for (final tool in values) {
      if (tool.manifestId == id) return tool;
    }
    // Unknown ids are ignored so a newer manifest does not break an older app.
    return null;
  }
}

/// Where a candidate came from. Declaration order is resolution precedence:
/// a developer's repo tree wins, a host install is the last resort.
enum ToolSource {
  /// App Studio downloaded it into Application Support and updates it.
  managed('Managed'),

  /// Already on this Mac — Homebrew, an SDK manager, a manual install. Ours to
  /// use, never ours to update.
  host('On your Mac');

  const ToolSource(this.label);

  final String label;
}

enum ToolFitness {
  /// Usable and within the accepted version range.
  satisfied,

  /// Runs, but the version is outside the accepted range.
  wrongVersion,

  /// The tree is there but files are missing — a partial or aborted install.
  incomplete,

  /// An Xcode Command Line Tools shim. Must never be executed: it pops a modal
  /// installer on a Mac without developer tools.
  stub,

  notFound,

  /// Present, but it failed to run or printed something unparseable.
  unusable,
}

class ToolCandidate {
  const ToolCandidate({
    required this.id,
    required this.source,
    required this.fitness,
    this.root,
    this.executable,
    this.detectedVersion,
    this.reason,
    this.facts = const {},
  });

  const ToolCandidate.notFound(this.id, this.source)
      : fitness = ToolFitness.notFound,
        root = null,
        executable = null,
        detectedVersion = null,
        reason = null,
        facts = const {};

  final ToolId id;
  final ToolSource source;
  final ToolFitness fitness;

  /// Install directory, when the tool has one.
  final String? root;

  /// Absolute path — never a bare command name, so a failure to resolve is
  /// reported here rather than thrown later by `Process.start`.
  final String? executable;
  final ToolVersion? detectedVersion;

  /// Human-readable explanation shown in the Tools Manager when not satisfied.
  final String? reason;

  /// Extra resolved paths a consumer needs: `gitExecPath`, `libDir`,
  /// `flutterRoot`, `dartExecutable`, `engineVersion`.
  final Map<String, String> facts;

  bool get isSatisfied => fitness == ToolFitness.satisfied;

  ToolCandidate copyWith({ToolFitness? fitness, String? reason}) {
    return ToolCandidate(
      id: id,
      source: source,
      fitness: fitness ?? this.fitness,
      root: root,
      executable: executable,
      detectedVersion: detectedVersion,
      reason: reason ?? this.reason,
      facts: facts,
    );
  }
}

class ToolStatus {
  ToolStatus({required this.spec, required List<ToolCandidate> candidates})
      : candidates = List.unmodifiable(candidates);

  final ToolSpec spec;

  /// In precedence order.
  final List<ToolCandidate> candidates;

  ToolId get id => spec.id;

  ToolCandidate? get resolved {
    for (final c in candidates) {
      if (c.isSatisfied) return c;
    }
    return null;
  }

  bool get isSatisfied => resolved != null;

  /// The best thing we found even though it did not qualify — drives the
  /// "3.5.0-beta.7 (needs >=4.0.0-beta.1)" line in the UI.
  ToolCandidate? get bestRejected {
    ToolCandidate? best;
    for (final c in candidates) {
      if (c.isSatisfied || c.fitness == ToolFitness.notFound) continue;
      best ??= c;
    }
    return best;
  }

  /// Required by the app but not usable. Drives warnings and the toolbar badge
  /// — deliberately independent of whether we have anything to install, so a
  /// tool we cannot supply still gets reported rather than silently ignored.
  bool get isMissing => !isSatisfied && spec.required;

  /// Whether an artifact exists for this platform that we could download.
  bool get canInstall => spec.artifactForCurrentPlatform != null;

  /// Missing *and* installable — this is what the download flow acts on.
  bool get needsDownload => isMissing && canInstall;
}

class ToolchainInventory {
  ToolchainInventory({required this.manifest, required this.tools});

  final ToolManifest manifest;
  final Map<ToolId, ToolStatus> tools;

  ToolStatus? operator [](ToolId id) => tools[id];

  bool isSatisfied(ToolId id) => tools[id]?.isSatisfied ?? false;

  /// Required tools that are not usable, whether or not we can supply them.
  List<ToolStatus> get missingRequired =>
      [for (final t in tools.values) if (t.isMissing) t];

  /// The subset we could actually download — what the install flow acts on.
  List<ToolStatus> get installable =>
      [for (final t in tools.values) if (t.needsDownload) t];

  bool get isComplete => missingRequired.isEmpty;

  /// Bytes to fetch for everything installable, for the preflight dialog.
  int get downloadBytes => installable.fold(
        0,
        (sum, t) => sum + (t.spec.artifactForCurrentPlatform?.downloadBytes ?? 0),
      );

  int get installedBytes => installable.fold(
        0,
        (sum, t) =>
            sum + (t.spec.artifactForCurrentPlatform?.installedBytes ?? 0),
      );
}
