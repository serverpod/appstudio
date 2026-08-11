/// Stand-ins for the real controllers, used by the widget previews.
///
/// They implement [ToolsView] and [ProvidersView] — the same interfaces the UI
/// talks to — so nothing here can drift from what the app renders without the
/// analyzer noticing. Free of `dart:io`, which is what makes the previews (a
/// web build) possible at all.
///
/// This lives under `lib/` rather than `test/` because the widget preview
/// scaffold only compiles the package's own sources. It is unreferenced by
/// `main.dart`, so it is tree-shaken out of release builds.
library;


import '../toolchain/install_progress.dart';
import '../toolchain/shell_path_state.dart';
import '../toolchain/tool_status.dart';
import '../toolchain/tool_version.dart';
import '../toolchain/toolchain_manifest.dart';
import '../ui/settings/providers_view.dart';
import '../ui/toolchain/tools_view.dart';


import 'package:flutter/foundation.dart';

// -----------------------------------------------------------------------------
// Fixtures
// -----------------------------------------------------------------------------

ToolSpec _spec(
  ToolId id,
  String displayName,
  String version, {
  bool required = true,
  int sizeMb = 120,
}) =>
    ToolSpec(
      id: id,
      displayName: displayName,
      description: 'Used to build and run Serverpod projects.',
      version: ToolVersion.tryParse(version)!,
      build: 1,
      hostAccepts: VersionRange.tryParse('*')!,
      required: required,
      installDir: '${id.manifestId}/$version',
      platforms: {
        'macos-arm64': ToolArtifact(
          path: 'tools/${id.manifestId}/$version/b1/${id.manifestId}.tar.gz',
          sha256: 'a' * 64,
          downloadBytes: sizeMb * 1024 * 1024,
          installedBytes: sizeMb * 3 * 1024 * 1024,
          format: 'tar.gz',
          stripComponents: 1,
        ),
      },
      entrypoints: const {},
      metadata: const {},
    );

/// A manifest with every tool the UI knows about.
final previewManifest = ToolManifest(
  manifestId: 'preview-1',
  baseUrl: Uri.parse('https://example.invalid/'),
  tools: {
    ToolId.flutter: _spec(ToolId.flutter, 'Flutter SDK', '3.44.2', sizeMb: 662),
    ToolId.serverpodCli:
        _spec(ToolId.serverpodCli, 'Serverpod CLI', '4.0.0-beta.2', sizeMb: 11),
    ToolId.opencode:
        _spec(ToolId.opencode, 'OpenCode', '1.18.4', required: false, sizeMb: 43),
    ToolId.git: _spec(ToolId.git, 'Git', '2.53.0-3', sizeMb: 57),
    ToolId.llvmTools:
        _spec(ToolId.llvmTools, 'Developer tools', '20.1.8', sizeMb: 9),
  },
);

ToolCandidate _found(ToolId id, ToolSource source, String version) =>
    ToolCandidate(
      id: id,
      source: source,
      fitness: ToolFitness.satisfied,
      root: '/preview/$id',
      executable: '/preview/$id/bin/${id.manifestId}',
      detectedVersion: ToolVersion.tryParse(version),
    );

ToolCandidate _tooOld(ToolId id, String version) => ToolCandidate(
      id: id,
      source: ToolSource.host,
      fitness: ToolFitness.wrongVersion,
      root: '/usr/local',
      executable: '/usr/local/bin/${id.manifestId}',
      detectedVersion: ToolVersion.tryParse(version),
      reason: 'Found $version, which is older than required',
    );

ToolchainInventory _inventory(Map<ToolId, List<ToolCandidate>> byTool) =>
    ToolchainInventory(
      manifest: previewManifest,
      tools: {
        for (final entry in byTool.entries)
          entry.key: ToolStatus(
            spec: previewManifest[entry.key]!,
            candidates: entry.value,
          ),
      },
    );

/// Everything installed and healthy.
final completeInventory = _inventory({
  ToolId.flutter: [_found(ToolId.flutter, ToolSource.managed, '3.44.2')],
  ToolId.serverpodCli: [
    _found(ToolId.serverpodCli, ToolSource.managed, '4.0.0-beta.2'),
  ],
  ToolId.opencode: [_found(ToolId.opencode, ToolSource.host, '1.18.4')],
  ToolId.git: [_found(ToolId.git, ToolSource.managed, '2.53.0-3')],
  ToolId.llvmTools: [_found(ToolId.llvmTools, ToolSource.managed, '20.1.8')],
});

/// First run: nothing found anywhere.
final emptyInventory = _inventory({
  for (final id in ToolId.values) id: const <ToolCandidate>[],
});

/// The awkward middle — one missing, one host copy too old to use.
final mixedInventory = _inventory({
  ToolId.flutter: [_found(ToolId.flutter, ToolSource.managed, '3.44.2')],
  ToolId.serverpodCli: [_tooOld(ToolId.serverpodCli, '4.0.0-beta.0')],
  ToolId.opencode: const <ToolCandidate>[],
  ToolId.git: [_found(ToolId.git, ToolSource.host, '2.53.0')],
  ToolId.llvmTools: [_found(ToolId.llvmTools, ToolSource.managed, '20.1.8')],
});

/// Every required tool already on this Mac, so the global-install opt-in has
/// nothing to add and shows satisfied and inert. OpenCode is managed on purpose
/// — it does not count towards this.
final allNativeInventory = _inventory({
  ToolId.flutter: [_found(ToolId.flutter, ToolSource.host, '3.44.2')],
  ToolId.serverpodCli: [
    _found(ToolId.serverpodCli, ToolSource.host, '4.0.0-beta.2'),
  ],
  ToolId.opencode: [_found(ToolId.opencode, ToolSource.managed, '1.18.4')],
  ToolId.git: [_found(ToolId.git, ToolSource.host, '2.53.0-3')],
  ToolId.llvmTools: [_found(ToolId.llvmTools, ToolSource.host, '20.1.8')],
});

/// Everything healthy, but two managed installs behind the pinned versions —
/// the only state in which "Update All" is enabled.
final outdatedInventory = _inventory({
  ToolId.flutter: [_found(ToolId.flutter, ToolSource.managed, '3.44.0')],
  ToolId.serverpodCli: [
    _found(ToolId.serverpodCli, ToolSource.managed, '4.0.0-beta.2'),
  ],
  ToolId.opencode: [_found(ToolId.opencode, ToolSource.host, '1.18.4')],
  // A host copy behind the pin stays put: we did not install it, so it is not
  // ours to replace, and Update All must leave it alone.
  ToolId.git: [_found(ToolId.git, ToolSource.host, '2.40.0')],
  ToolId.llvmTools: [_found(ToolId.llvmTools, ToolSource.managed, '20.1.0')],
});

/// A download in flight, so the progress banner can be seen without waiting
/// for a real 662 MB transfer.
/// Fixed [startedAt] and [now] so the banner's elapsed/remaining text is
/// identical on every run.
final downloadingProgress = InstallProgress(
  startedAt: DateTime.utc(2026, 1, 1, 12),
  now: DateTime.utc(2026, 1, 1, 12, 0, 40),
  tools: const [
    ToolProgress(
      id: ToolId.flutter,
      phase: ToolPhase.downloading,
      receivedBytes: 271 * 1024 * 1024,
      totalBytes: 662 * 1024 * 1024,
    ),
    ToolProgress(id: ToolId.serverpodCli, phase: ToolPhase.queued),
  ],
);

/// The tail of an install: every download has landed, and the re-probe and the
/// shell PATH write are still running. The UI stays on the progress view here
/// rather than dropping back to the plan for a second.
final finishingProgress = InstallProgress(
  startedAt: DateTime.utc(2026, 1, 1, 12),
  now: DateTime.utc(2026, 1, 1, 12, 2, 10),
  tools: const [
    ToolProgress(
      id: ToolId.flutter,
      phase: ToolPhase.done,
      receivedBytes: 662 * 1024 * 1024,
      totalBytes: 662 * 1024 * 1024,
    ),
    ToolProgress(
      id: ToolId.serverpodCli,
      phase: ToolPhase.done,
      receivedBytes: 11 * 1024 * 1024,
      totalBytes: 11 * 1024 * 1024,
    ),
  ],
);

// -----------------------------------------------------------------------------
// Fakes
// -----------------------------------------------------------------------------

/// A [ToolsView] whose state is whatever you pass in.
///
/// Actions are no-ops that still notify, so buttons visibly do *something* in
/// a preview without touching the machine.
class FakeToolsView extends ChangeNotifier implements ToolsView {
  FakeToolsView({
    ToolchainInventory? inventory,
    this.progress,
    this.installError,
    this.isBusy = false,
    this.isInstalling = false,
    this.preflightError,
    this.preflightDelay = Duration.zero,
    this.shellPathState = ShellPathState.absent,
    this.shellName = 'zsh',
    this.shellRcLabel = '~/.zshrc',
    this.shellExportLine =
        'export PATH="\$HOME/Library/Application Support/App Studio/bin:\$PATH"',
  }) : inventory = inventory ?? completeInventory;

  @override
  ToolchainInventory inventory;
  @override
  InstallProgress? progress;
  @override
  String? installError;
  @override
  bool isBusy;
  @override
  bool isInstalling;

  /// What [preflight] reports back. Non-null drives the setup screen's failure
  /// path, which is otherwise only reachable by unplugging the network.
  String? preflightError;

  /// Held before [preflight] answers, so the setup screen's spinner is visible
  /// long enough to look at.
  Duration preflightDelay;

  @override
  ShellPathState shellPathState;
  @override
  String shellName;
  @override
  String shellRcLabel;
  @override
  String shellExportLine;

  @override
  Future<void> refreshDeep() async => notifyListeners();
  @override
  Future<void> refreshShellPathState() async {}
  @override
  Future<String?> preflight() async {
    if (preflightDelay > Duration.zero) await Future.delayed(preflightDelay);
    notifyListeners();
    return preflightError;
  }
  @override
  Future<void> install(List<ToolId> ids) async => notifyListeners();
  @override
  Future<void> installMissing() async => notifyListeners();
  @override
  Future<void> uninstall(ToolId id) async => notifyListeners();
  @override
  void cancelInstall() => notifyListeners();
  @override
  Future<String?> setShellPathEnabled(bool enabled, {bool force = false}) async {
    shellPathState = enabled ? ShellPathState.present : ShellPathState.absent;
    notifyListeners();
    return null;
  }

}

/// A [ProvidersView] with a fixed set of keys and models.
class FakeProvidersView extends ChangeNotifier implements ProvidersView {
  FakeProvidersView({
    Set<String>? connected,
    this.defaultModel,
    this.models = const [],
    this.agentReady = true,
  }) : _connected = connected ?? <String>{};

  final Set<String> _connected;

  /// False reproduces the pane's waiting state — what Settings shows while
  /// `opencode serve` is still coming up, or with no project open.
  @override
  final bool agentReady;

  @override
  Iterable<String> get connectedProviders => _connected;

  @override
  String? defaultModel;

  List<ProviderModel> models;

  @override
  Future<List<ProviderModel>> listModels() async => models;

  @override
  Future<void> saveApiKey(String providerId, String key) async {
    _connected.add(providerId);
    notifyListeners();
  }

  @override
  Future<void> removeApiKey(String providerId) async {
    _connected.remove(providerId);
    notifyListeners();
  }

  @override
  void setDefaultModel(String value) {
    defaultModel = value;
    notifyListeners();
  }
}

/// A couple of providers connected, with models to choose between.
FakeProvidersView connectedProvidersFake() => FakeProvidersView(
      connected: {'anthropic', 'openai'},
      defaultModel: 'anthropic/claude-opus-5',
      models: const [
        ProviderModel(
          providerId: 'anthropic',
          modelId: 'claude-opus-5',
          label: 'Claude Opus 5',
        ),
        ProviderModel(
          providerId: 'anthropic',
          modelId: 'claude-sonnet-5',
          label: 'Claude Sonnet 5',
        ),
        ProviderModel(
          providerId: 'openai',
          modelId: 'gpt-5',
          label: 'GPT-5',
        ),
      ],
    );
