import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../theme/app_theme.dart';
import '../../agent/agent_transcript.dart';
import 'providers_view.dart';

/// Provider keys and the default model, as a pane inside the Settings dialog.
///
/// Deliberately not a dialog of its own: it shares a window with the Tools
/// pane, so it owns no chrome, no title and no Done button.
class ProvidersSettingsPane extends StatefulWidget {
  const ProvidersSettingsPane({super.key, required this.agent});

  final ProvidersView agent;

  @override
  State<ProvidersSettingsPane> createState() => _ProvidersSettingsPaneState();
}

class _ProvidersSettingsPaneState extends State<ProvidersSettingsPane> {
  final Map<String, TextEditingController> _keyControllers = {};
  final Map<String, bool> _saving = {};
  List<ProviderModel> _models = [];
  bool _loadingModels = false;
  String? _error;

  /// Tracks the edge into [ProvidersView.agentReady], so the retry fires once.
  bool _wasReady = false;

  @override
  void initState() {
    super.initState();
    for (final p in curatedProviders) {
      _keyControllers[p.id] = TextEditingController();
    }
    widget.agent.addListener(_onAgent);
    _wasReady = widget.agent.agentReady;
    unawaited(_loadModels());
  }

  @override
  void dispose() {
    widget.agent.removeListener(_onAgent);
    for (final c in _keyControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onAgent() {
    if (!mounted) return;
    // The pane can open before the agent answers, in which case the first
    // model load came back empty. Retry on the edge into ready.
    final ready = widget.agent.agentReady;
    if (ready && !_wasReady) unawaited(_loadModels());
    _wasReady = ready;
    setState(() {});
  }

  Future<void> _loadModels() async {
    setState(() {
      _loadingModels = true;
      _error = null;
    });
    try {
      _models = await widget.agent.listModels();
    } catch (e) {
      _error = e.toString();
      _models = [];
    }
    if (mounted) {
      setState(() => _loadingModels = false);
    }
  }

  Future<void> _save(String providerId) async {
    final key = _keyControllers[providerId]?.text.trim() ?? '';
    if (key.isEmpty) return;
    setState(() => _saving[providerId] = true);
    try {
      await widget.agent.saveApiKey(providerId, key);
      _keyControllers[providerId]?.clear();
      await _loadModels();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving[providerId] = false);
    }
  }

  Future<void> _remove(String providerId) async {
    setState(() => _saving[providerId] = true);
    try {
      await widget.agent.removeApiKey(providerId);
      await _loadModels();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving[providerId] = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final connected = widget.agent.connectedProviders.toSet();
    // Also treat auth-store keys as connected for display when serve is down.
    final defaultModel = widget.agent.defaultModel;

    // Before the agent answers, "which providers hold a key" and "which models
    // exist" are unknown rather than empty. Rendering the list anyway would
    // show every provider as disconnected and no models at all — an answer, and
    // the wrong one.
    if (!widget.agent.agentReady) {
      return const _WaitingForAgent();
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            Text(
              _error!,
              style: theme.textTheme.muted.copyWith(color: scheme.destructive),
            ),
            const ShadGap(3),
          ],
          Text('Default model', style: theme.textTheme.small.semibold),
          const ShadGap(1.5),
          if (_loadingModels)
            Text('Loading models…', style: theme.textTheme.muted)
          else if (_models.isEmpty)
            Text(
              connected.isEmpty
                  ? 'Add a provider key to choose a default model.'
                  : 'No models available yet.',
              style: theme.textTheme.muted,
            )
          else
            ShadSelect<String>(
              initialValue: defaultModel,
              placeholder: const Text('Select model'),
              options: [
                for (final m in _models)
                  ShadOption(
                    value: '${m.providerId}/${m.modelId}',
                    child: Text(m.label),
                  ),
              ],
              selectedOptionBuilder: (context, value) {
                for (final m in _models) {
                  if ('${m.providerId}/${m.modelId}' == value) {
                    return Text(m.label);
                  }
                }
                return Text(value);
              },
              onChanged: (value) {
                if (value != null) {
                  widget.agent.setDefaultModel(value);
                }
              },
            ),
          const ShadGap(4),
          for (final provider in curatedProviders) ...[
            _ProviderRow(
              provider: provider,
              connected: connected.contains(provider.id),
              controller: _keyControllers[provider.id]!,
              saving: _saving[provider.id] == true,
              onSave: () => _save(provider.id),
              onRemove: connected.contains(provider.id)
                  ? () => _remove(provider.id)
                  : null,
            ),
            const ShadGap(2),
          ],
        ],
      ),
    );
  }
}

/// Stands in for the provider list until `opencode serve` answers.
///
/// Worded to be true in both cases that reach it: the agent still starting, and
/// no project open at all — in which case there is nothing for it to start on.
class _WaitingForAgent extends StatelessWidget {
  const _WaitingForAgent();

  @override
  Widget build(BuildContext context) {
    return const ShadEmpty(
      icon: ShadSpinner(),
      title: Text('Waiting for the agent'),
      description: Text(
        'Your provider keys and the list of models come from the agent, '
        'which starts with the open project.',
      ),
    );
  }
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({
    required this.provider,
    required this.connected,
    required this.controller,
    required this.saving,
    required this.onSave,
    required this.onRemove,
  });

  final CuratedProvider provider;
  final bool connected;
  final TextEditingController controller;
  final bool saving;
  final VoidCallback onSave;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;

    return ShadCard(
      // `card` is the page background in slate, so a card only reads by its
      // border. `muted` is the palette's alternate surface — the same token
      // the pane headers use — which separates the rows from the dialog.
      backgroundColor: scheme.muted,
      title: Text(provider.label),
      // `action`, not `trailing`: trailing sits beside the card's whole content
      // column and would squeeze the input row: `action` occupies only the
      // header, so the body keeps the card's full width.
      action: Text(
        connected ? 'Connected' : 'Not connected',
        style: theme.textTheme.muted.copyWith(
          color: connected ? scheme.success : scheme.mutedForeground,
        ),
      ),
      child: ShadRow(
        spacing: 2,
        children: [
          Expanded(
            child: ShadInput(
              controller: controller,
              obscureText: true,
              // The card is a muted fill, which the input's own transparent
              // one disappears into.
              decoration: ShadDecoration(color: scheme.background),
              placeholder: Text(
                connected
                    ? 'Replace ${provider.label} API key…'
                    : 'Add ${provider.label} API key…',
              ),
            ),
          ),
          ShadButton(
            onPressed: saving ? null : onSave,
            child: Text(saving ? '…' : 'Save'),
          ),
          if (onRemove != null)
            ShadButton.destructive(
              onPressed: saving ? null : onRemove,
              child: const Text('Remove'),
            ),
        ],
      ),
    );
  }
}
