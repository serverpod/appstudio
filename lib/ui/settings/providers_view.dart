import 'package:flutter/foundation.dart';

/// One selectable model, flattened for display.
///
/// Declared here rather than reused from the OpenCode client so this file —
/// and everything that renders it — stays free of `dart:io`.
@immutable
class ProviderModel {
  const ProviderModel({
    required this.providerId,
    required this.modelId,
    required this.label,
  });

  final String providerId;
  final String modelId;
  final String label;

  String get value => '$providerId/$modelId';
}

/// Everything the Providers pane needs, and nothing that touches the disk.
///
/// `AgentController` implements this directly. The pane imports only this file,
/// so it never pulls in the OpenCode auth store — which reads and writes
/// `~/.local/share/opencode/auth.json` and would make the pane impossible to
/// preview.
abstract interface class ProvidersView implements Listenable {
  /// Whether the agent is up.
  ///
  /// Until it is, [connectedProviders] and [listModels] have nothing to report
  /// — not "none", but "not known yet". The pane waits rather than rendering an
  /// empty list, which would read as an answer and invite the user to re-enter
  /// keys they have already saved.
  bool get agentReady;

  /// Provider ids with a key already stored.
  Iterable<String> get connectedProviders;

  /// `provider/model`, or null when none has been chosen.
  String? get defaultModel;

  /// Models the running agent offers. Returns empty when the agent is not up,
  /// which is the normal state before any key is entered.
  Future<List<ProviderModel>> listModels();

  Future<void> saveApiKey(String providerId, String key);
  Future<void> removeApiKey(String providerId);
  void setDefaultModel(String value);
}
