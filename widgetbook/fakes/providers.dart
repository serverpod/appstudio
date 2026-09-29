/// A [ProvidersView] fake — the agent's provider keys and models, shared by
/// Widgetbook and the widget tests.
library;

import 'package:appstudio/ui/settings/providers_view.dart';
import 'package:flutter/foundation.dart';

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
