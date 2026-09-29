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

import 'package:flutter/foundation.dart';

import '../toolchain/install_plan.dart';
import '../toolchain/install_progress.dart';
import '../toolchain/tool_status.dart';
import '../toolchain/tool_version.dart';
import '../toolchain/toolchain_manifest.dart';
import '../ui/settings/providers_view.dart';
import '../ui/toolchain/tools_view.dart';

// -----------------------------------------------------------------------------
// Fixtures
// -----------------------------------------------------------------------------

ToolSpec _spec(ToolId id, String accepts) => ToolSpec(
      id: id,
      displayName: id.displayName,
      description: 'Used to build and run Serverpod projects.',
      accepts: VersionRange.tryParse(accepts)!,
    );

/// A manifest with every tool the UI knows about.
final previewManifest = ToolManifest(
  tools: {
    ToolId.commandLineTools: _spec(ToolId.commandLineTools, '*'),
    ToolId.flutter: _spec(ToolId.flutter, '>=3.47.0'),
    ToolId.serverpodCli: _spec(ToolId.serverpodCli, '>=4.0.0 <4.1.0'),
  },
);

ToolCandidate _found(ToolId id, ToolSource source, String? version) =>
    ToolCandidate(
      id: id,
      source: source,
      fitness: ToolFitness.satisfied,
      root: '/preview/${id.manifestId}',
      executable: '/preview/${id.manifestId}/bin/${id.manifestId}',
      detectedVersion: ToolVersion.tryParse(version),
    );

ToolCandidate _tooOld(ToolId id, String version, {String root = '/usr/local'}) =>
    ToolCandidate(
      id: id,
      source: ToolSource.host,
      fitness: ToolFitness.wrongVersion,
      root: root,
      executable: '$root/bin/${id.manifestId}',
      detectedVersion: ToolVersion.tryParse(version),
      reason: '$version (needs ${previewManifest[id]!.accepts})',
      facts: const {'channel': 'stable'},
    );

ToolchainInventory _inventory(
  Map<ToolId, (List<ToolCandidate>, ToolAction)> byTool, {
  bool legacy = false,
}) =>
    ToolchainInventory(
      manifest: previewManifest,
      legacyInstallFound: legacy,
      tools: {
        for (final entry in byTool.entries)
          entry.key: ToolStatus(
            spec: previewManifest[entry.key]!,
            candidates: entry.value.$1,
            action: entry.value.$2,
          ),
      },
    );

/// Everything installed and healthy — Flutter and the Serverpod CLI by App
/// Studio, the Command Line Tools already there.
final completeInventory = _inventory({
  ToolId.commandLineTools: (
    [_found(ToolId.commandLineTools, ToolSource.host, null)],
    ToolAction.none,
  ),
  ToolId.flutter: (
    [_found(ToolId.flutter, ToolSource.appStudio, '3.47.5')],
    ToolAction.none,
  ),
  ToolId.serverpodCli: (
    [_found(ToolId.serverpodCli, ToolSource.appStudio, '4.0.3')],
    ToolAction.none,
  ),
});

/// First run on a clean Mac: nothing found anywhere.
final emptyInventory = _inventory({
  for (final id in ToolId.values) id: (const <ToolCandidate>[], ToolAction.install),
});

/// The awkward middle — developer tools already there, Flutter missing, and a
/// Serverpod CLI too old to use.
final mixedInventory = _inventory({
  ToolId.commandLineTools: (
    [_found(ToolId.commandLineTools, ToolSource.host, null)],
    ToolAction.none,
  ),
  ToolId.flutter: (const <ToolCandidate>[], ToolAction.install),
  ToolId.serverpodCli: (
    [_tooOld(ToolId.serverpodCli, '3.4.1')],
    ToolAction.update,
  ),
});

/// The user's own Flutter is too old, and App Studio leaves updating it to
/// them.
final manualUpdateInventory = _inventory({
  ToolId.commandLineTools: (
    [_found(ToolId.commandLineTools, ToolSource.host, null)],
    ToolAction.none,
  ),
  ToolId.flutter: (
    [_tooOld(ToolId.flutter, '3.41.2', root: '/Users/preview/flutter')],
    ToolAction.manual,
  ),
  ToolId.serverpodCli: (
    [_found(ToolId.serverpodCli, ToolSource.host, '4.0.3')],
    ToolAction.none,
  ),
});

/// A build from before this one left its own toolchain behind.
final legacyInventory = _inventory(
  {for (final id in ToolId.values) id: (const <ToolCandidate>[], ToolAction.install)},
  legacy: true,
);

/// What preflight finds for [emptyInventory].
final previewPlan = InstallPlan({
  ToolId.commandLineTools: const PlannedTool(id: ToolId.commandLineTools),
  ToolId.flutter: PlannedTool(
    id: ToolId.flutter,
    version: ToolVersion.tryParse('3.47.5'),
    flutterRelease: FlutterRelease(
      version: ToolVersion.tryParse('3.47.5')!,
      archiveUrl: Uri.parse('https://example.invalid/flutter.zip'),
      sha256: 'a' * 64,
      downloadBytes: 2262108309,
    ),
  ),
  ToolId.serverpodCli: PlannedTool(
    id: ToolId.serverpodCli,
    version: ToolVersion.tryParse('4.0.3'),
  ),
});

/// A download in flight, so the progress view can be seen without waiting for
/// a real 2 GB transfer. Fixed times so the remaining-time text is identical
/// on every run.
final downloadingProgress = InstallProgress(
  startedAt: DateTime.utc(2026, 1, 1, 12),
  now: DateTime.utc(2026, 1, 1, 12, 0, 40),
  tools: [
    const ToolProgress(id: ToolId.commandLineTools, phase: ToolPhase.done),
    ToolProgress(
      id: ToolId.flutter,
      phase: ToolPhase.downloading,
      receivedBytes: 871 * 1000 * 1000,
      totalBytes: 2262 * 1000 * 1000,
      phaseStartedAt: DateTime.utc(2026, 1, 1, 12),
    ),
    const ToolProgress(id: ToolId.serverpodCli, phase: ToolPhase.queued),
  ],
);

/// Apple's installer is up and App Studio is waiting on it.
final waitingForAppleProgress = InstallProgress(
  startedAt: DateTime.utc(2026, 1, 1, 12),
  now: DateTime.utc(2026, 1, 1, 12, 1),
  tools: const [
    ToolProgress(id: ToolId.commandLineTools, phase: ToolPhase.waitingForApple),
    ToolProgress(id: ToolId.flutter, phase: ToolPhase.queued),
    ToolProgress(id: ToolId.serverpodCli, phase: ToolPhase.queued),
  ],
);

/// The tail of an install: every step has finished and the re-probe is still
/// running. The UI stays on the progress view here rather than dropping back
/// to the plan for a second.
final finishingProgress = InstallProgress(
  startedAt: DateTime.utc(2026, 1, 1, 12),
  now: DateTime.utc(2026, 1, 1, 12, 6, 10),
  tools: const [
    ToolProgress(id: ToolId.commandLineTools, phase: ToolPhase.done),
    ToolProgress(id: ToolId.flutter, phase: ToolPhase.done),
    ToolProgress(id: ToolId.serverpodCli, phase: ToolPhase.done),
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
    InstallPlan? plan,
    this.progress,
    this.installError,
    this.isBusy = false,
    this.isInstalling = false,
    this.preflightError,
    this.preflightDelay = Duration.zero,
    this.flutterInstallLabel = '~/develop/flutter',
    this.shellProfileLabel = '~/.zprofile',
    this.manualPathLines = const [],
  })  : inventory = inventory ?? completeInventory,
        plan = plan ?? previewPlan;

  @override
  ToolchainInventory inventory;
  @override
  InstallPlan plan;
  @override
  InstallProgress? progress;
  @override
  String? installError;
  @override
  bool isBusy;
  @override
  bool isInstalling;
  @override
  String flutterInstallLabel;
  @override
  String? shellProfileLabel;
  @override
  List<String> manualPathLines;

  /// What [preflight] reports back. Non-null drives the setup screen's failure
  /// path, which is otherwise only reachable by unplugging the network.
  String? preflightError;

  /// Held before [preflight] answers, so the setup screen's spinner is visible
  /// long enough to look at.
  Duration preflightDelay;

  /// Counts the calls, for tests that drive the setup screen.
  int legacyRemovals = 0;

  @override
  Future<void> refreshDeep() async => notifyListeners();
  @override
  Future<String?> preflight() async {
    if (preflightDelay > Duration.zero) await Future.delayed(preflightDelay);
    notifyListeners();
    return preflightError;
  }

  @override
  Future<void> installMissing() async => notifyListeners();
  @override
  void cancelInstall() => notifyListeners();
  @override
  Future<String?> removeLegacyInstall() async {
    legacyRemovals++;
    inventory = ToolchainInventory(
      manifest: inventory.manifest,
      tools: inventory.tools,
    );
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
