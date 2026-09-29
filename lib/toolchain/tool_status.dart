import 'toolchain_manifest.dart';
import 'tool_version.dart';

/// The tools App Studio needs, in install order: the Command Line Tools
/// supply the `git` Flutter runs on, and the Serverpod CLI is installed with
/// Flutter's own `dart`.
enum ToolId {
  commandLineTools('command_line_tools', 'Command Line Tools'),
  flutter('flutter', 'Flutter SDK'),
  serverpodCli('serverpod_cli', 'Serverpod CLI');

  const ToolId(this.manifestId, this.displayName);

  final String manifestId;
  final String displayName;

  static ToolId? fromManifestId(String id) {
    for (final tool in values) {
      if (tool.manifestId == id) return tool;
    }
    // Unknown ids are ignored so a newer file does not break an older app.
    return null;
  }
}

/// Who put a tool on this Mac.
///
/// Both are ordinary installs in the ordinary places — App Studio no longer
/// keeps a private copy of anything. The difference is only whose it is to
/// update and to offer for removal.
enum ToolSource {
  /// Installed by App Studio, according to the install record in
  /// `~/.serverpod`.
  appStudio('App Studio'),

  /// Already on this Mac — installed by hand, by Homebrew, by an SDK manager.
  host('Native');

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

  notFound,

  /// Present, but it failed to run or printed something unparseable.
  unusable,
}

/// What getting a tool into shape takes.
enum ToolAction {
  /// Nothing — it is usable.
  none,

  /// App Studio installs it from scratch.
  install,

  /// App Studio updates a copy it installed itself (`flutter upgrade`), or
  /// reinstalls one that is cheap to replace (`dart install`).
  update,

  /// There is a copy App Studio did not install and must not touch — the user
  /// updates it themselves. In practice: their own Flutter is too old.
  manual;

  /// Whether App Studio can carry this out on its own.
  bool get isAutomatic => this == install || this == update;
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

  /// Human-readable explanation shown when not satisfied.
  final String? reason;

  /// Extra resolved paths a consumer needs: `flutterRoot`, `dartExecutable`,
  /// `channel`.
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
  ToolStatus({
    required this.spec,
    required List<ToolCandidate> candidates,
    this.action = ToolAction.none,
  }) : candidates = List.unmodifiable(candidates);

  final ToolSpec spec;

  /// In precedence order.
  final List<ToolCandidate> candidates;

  /// Decided by the probe, which is the one place that knows both what is on
  /// disk and what App Studio installed.
  final ToolAction action;

  ToolId get id => spec.id;

  ToolCandidate? get resolved {
    for (final c in candidates) {
      if (c.isSatisfied) return c;
    }
    return null;
  }

  bool get isSatisfied => resolved != null;

  /// The best thing we found even though it did not qualify — drives the
  /// "3.44.0 → 3.47.5" badge and the reason text.
  ToolCandidate? get bestRejected {
    for (final c in candidates) {
      if (c.isSatisfied || c.fitness == ToolFitness.notFound) continue;
      return c;
    }
    return null;
  }

  /// Not usable. Drives the toolbar badge.
  bool get isMissing => !isSatisfied;
}

class ToolchainInventory {
  ToolchainInventory({
    required this.manifest,
    required this.tools,
    this.legacyInstallFound = false,
  });

  final ToolManifest manifest;
  final Map<ToolId, ToolStatus> tools;

  /// A toolchain from a build that kept its own copies in Application Support,
  /// or the `PATH` block it wrote. Setup removes both before installing the
  /// new way.
  final bool legacyInstallFound;

  ToolStatus? operator [](ToolId id) => tools[id];

  bool isSatisfied(ToolId id) => tools[id]?.isSatisfied ?? false;

  /// Tools that are not usable, whatever it takes to fix them.
  List<ToolStatus> get missingRequired =>
      [for (final t in tools.values) if (t.isMissing) t];

  /// What App Studio can install or update on its own — what the install flow
  /// acts on.
  List<ToolStatus> get installable => [
        for (final id in ToolId.values)
          if (tools[id] case final t? when t.action.isAutomatic) t,
      ];

  /// Copies the user has to update themselves before anything else can go on.
  List<ToolStatus> get needsManualUpdate =>
      [for (final t in tools.values) if (t.action == ToolAction.manual) t];

  bool get isComplete => missingRequired.isEmpty;

  /// Whether first-run setup still owns the window.
  ///
  /// Named because three things have to agree on it: the screen `main.dart`
  /// picks, the App menu items that would walk straight past that screen
  /// (File → Open, Open Recent, Settings), and [StudioShell]'s own settings
  /// route. Written out three times, they would drift.
  bool get needsSetup =>
      legacyInstallFound ||
      installable.isNotEmpty ||
      needsManualUpdate.isNotEmpty;
}
