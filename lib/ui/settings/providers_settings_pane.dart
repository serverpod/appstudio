import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../agent/agent_transcript.dart';
import '../../theme/app_theme.dart';
import '../../widgets/settings_table.dart';
import 'add_provider_dialog.dart';
import 'providers_view.dart';

/// Provider keys and the default model, as a pane inside the Settings dialog.
///
/// Deliberately not a dialog of its own: it shares a window with the Tools
/// pane, so it owns no chrome, no title and no Done button — and it uses the
/// same [SettingsTable], so the two tabs read as one window rather than two
/// screens that happen to be adjacent.
///
/// Only *connected* providers are listed. The pane used to render a card with a
/// key field for all seventeen curated providers, so the answer to "which keys
/// do I have?" was buried in a wall of empty inputs.
class ProvidersSettingsPane extends StatefulWidget {
  const ProvidersSettingsPane({super.key, required this.agent});

  final ProvidersView agent;

  @override
  State<ProvidersSettingsPane> createState() => _ProvidersSettingsPaneState();
}

class _ProvidersSettingsPaneState extends State<ProvidersSettingsPane> {
  List<ProviderModel> _models = [];
  bool _loadingModels = false;
  String? _error;

  /// Providers with a write in flight, so their row cannot be acted on twice.
  final Set<String> _busy = {};

  /// Tracks the edge into [ProvidersView.agentReady], so the retry fires once.
  bool _wasReady = false;

  @override
  void initState() {
    super.initState();
    widget.agent.addListener(_onAgent);
    _wasReady = widget.agent.agentReady;
    unawaited(_loadModels());
  }

  @override
  void dispose() {
    widget.agent.removeListener(_onAgent);
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

  Future<void> _addProvider() async {
    final added = await showAddProviderDialog(
      context,
      connected: widget.agent.connectedProviders.toSet(),
      onConnect: _connect,
    );
    if (added && mounted) await _loadModels();
  }

  /// Stores a key and checks the agent actually took it.
  ///
  /// Nothing here validates the key itself — `saveApiKey` writes it to the auth
  /// store and treats that as the source of truth, so a well-formed but wrong
  /// key succeeds. What this can catch is the write failing, and the agent not
  /// reporting the provider as connected afterwards, which is the difference
  /// between "your key is wrong" and "that did not take effect".
  Future<String?> _connect(String providerId, String apiKey) async {
    try {
      await widget.agent.saveApiKey(providerId, apiKey);
    } catch (e) {
      return '$e';
    }
    if (!widget.agent.connectedProviders.contains(providerId)) {
      return 'The key was saved, but the agent did not report the provider as '
          'connected. It may still be starting up.';
    }
    return null;
  }

  Future<void> _remove(String providerId) async {
    setState(() => _busy.add(providerId));
    try {
      await widget.agent.removeApiKey(providerId);
      await _loadModels();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy.remove(providerId));
    }
  }

  String _labelFor(String id) => curatedProviders
      .firstWhere(
        (p) => p.id == id,
        // A key for something not on the curated list still deserves a row.
        orElse: () => CuratedProvider(id: id, label: id),
      )
      .label;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final connected = widget.agent.connectedProviders.toList()..sort();

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
              initialValue: widget.agent.defaultModel,
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
                if (value != null) widget.agent.setDefaultModel(value);
              },
            ),
          const ShadGap(4),
          Text('Providers', style: theme.textTheme.small.semibold),
          const ShadGap(1.5),
          if (connected.isEmpty)
            Text(
              'No API keys yet. Add one to pick a model for the agent.',
              style: theme.textTheme.muted,
            )
          else
            SettingsTable(
              rows: [
                for (final id in connected)
                  SettingsTableRow(
                    name: _labelFor(id),
                    badge: appSuccessBadge(
                      theme,
                      child: const Text('Connected'),
                    ),
                    trailing: _RemoveKeyButton(
                      key: ValueKey('remove-key-$id'),
                      label: _labelFor(id),
                      onPressed: _busy.contains(id) ? null : () => _remove(id),
                    ),
                  ),
              ],
            ),
          const ShadGap(3),
          Align(
            alignment: Alignment.centerRight,
            child: ShadButton.outline(
              onPressed: _addProvider,
              child: const Text('Add Provider'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Removes a stored key. Icon-only, because the row already names the provider.
class _RemoveKeyButton extends StatelessWidget {
  const _RemoveKeyButton({
    super.key,
    required this.label,
    required this.onPressed,
  });

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return ShadTooltip(
      builder: (context) => Text('Remove the $label key'),
      child: ShadIconButton.ghost(
        // `enabled` as well as `onPressed`: shad dims from the flag alone.
        enabled: enabled,
        onPressed: onPressed,
        icon: const Icon(LucideIcons.trash2, size: 16),
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
