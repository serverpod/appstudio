import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

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

  @override
  void initState() {
    super.initState();
    for (final p in curatedProviders) {
      _keyControllers[p.id] = TextEditingController();
    }
    widget.agent.addListener(_onAgent);
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
    if (mounted) setState(() {});
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

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'API keys are stored in OpenCode\u2019s credential file and shared '
            'with the CLI.',
            style: theme.textTheme.muted,
          ),
          const SizedBox(height: 14),
          if (_error != null) ...[
            Text(
              _error!,
              style: theme.textTheme.muted.copyWith(
                color: scheme.destructive,
              ),
            ),
            const SizedBox(height: 12),
          ],
          Text(
            'Default model',
            style: theme.textTheme.small.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
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
          const SizedBox(height: 16),
          Divider(color: scheme.border, height: 1),
          const SizedBox(height: 12),
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
            const SizedBox(height: 10),
          ],
    ],
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

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.muted.withValues(alpha: 0.45),
        borderRadius: theme.radii.md,
        border: Border.all(color: scheme.border.withValues(alpha: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    provider.label,
                    style: theme.textTheme.small.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  connected ? 'Connected' : 'Not connected',
                  style: theme.textTheme.muted.copyWith(
                    fontSize: 11,
                    color: connected ? scheme.primary : scheme.mutedForeground,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ShadInput(
                    controller: controller,
                    obscureText: true,
                    placeholder: Text(
                      connected ? 'Replace API key…' : 'Paste API key…',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ShadButton(
                  size: ShadButtonSize.sm,
                  onPressed: saving ? null : onSave,
                  child: Text(saving ? '…' : 'Save'),
                ),
                if (onRemove != null) ...[
                  const SizedBox(width: 6),
                  ShadButton.ghost(
                    size: ShadButtonSize.sm,
                    onPressed: saving ? null : onRemove,
                    child: const Text('Remove'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
