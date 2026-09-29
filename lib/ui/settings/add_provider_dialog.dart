import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../agent/agent_transcript.dart';
import '../../widgets/error_banner.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/dialog_body.dart';

/// Stores the key and reports back. Returns null on success, or a message to
/// show without closing the dialog.
typedef ConnectProvider = Future<String?> Function(
  String providerId,
  String apiKey,
);

/// Narrower than the Settings dialog it opens over, so the two read as
/// foreground and background rather than one replacing the other.
///
/// Set on the dialog rather than on its child: `ShadDialog` sizes itself to its
/// widest content, so a fixed-width child inside a wider dialog just leaves the
/// inputs floating short of the edge.
const _kDialogConstraints = BoxConstraints(maxWidth: 380);

/// Asks for a provider and its key, and keeps asking until [onConnect] succeeds
/// or the user cancels. Returns true when a key was stored.
///
/// [connected] are the providers that already hold a key; they are left out of
/// the list, because the answer for those is to remove the row and add it again
/// rather than to "add" a second time.
Future<bool> showAddProviderDialog(
  BuildContext context, {
  required Set<String> connected,
  required ConnectProvider onConnect,
}) async {
  final added = await showAppDialog<bool>(
    context: context,
    builder: (context) => AddProviderDialog(
      connected: connected,
      onConnect: onConnect,
    ),
  );
  return added ?? false;
}

class AddProviderDialog extends StatefulWidget {
  const AddProviderDialog({
    super.key,
    required this.connected,
    required this.onConnect,
  });

  final Set<String> connected;
  final ConnectProvider onConnect;

  @override
  State<AddProviderDialog> createState() => _AddProviderDialogState();
}

class _AddProviderDialogState extends State<AddProviderDialog> {
  final _keyController = TextEditingController();
  String? _providerId;
  String? _error;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    // Enables Connect the moment both fields are filled, without a listener on
    // the dialog's whole state.
    _keyController.addListener(_onKeyChanged);
  }

  @override
  void dispose() {
    _keyController.removeListener(_onKeyChanged);
    _keyController.dispose();
    super.dispose();
  }

  void _onKeyChanged() => setState(() {});

  List<CuratedProvider> get _available => [
        for (final p in curatedProviders)
          if (!widget.connected.contains(p.id)) p,
      ];

  bool get _canConnect =>
      !_connecting &&
      _providerId != null &&
      _keyController.text.trim().isNotEmpty;

  Future<void> _connect() async {
    if (!_canConnect) return;
    setState(() {
      _connecting = true;
      _error = null;
    });
    final error = await widget.onConnect(
      _providerId!,
      _keyController.text.trim(),
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }
    // Stays open with the key still in the field: retyping it is the last thing
    // anyone wants to do after a failure.
    setState(() {
      _connecting = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final available = _available;

    // The alert variant, whose theme carries no `closeIconData`: Cancel is the
    // way out, and a close X beside it would be a second one that says less.
    return ShadDialog.alert(
      constraints: _kDialogConstraints,
      title: const Text('Add provider'),
      description: const Text(
        'The key is stored by the agent, and is never sent anywhere else.',
      ),
      actions: [
        ShadButton.outline(
          enabled: !_connecting,
          onPressed: _connecting ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ShadButton(
          // `enabled` as well as `onPressed`: shad dims from the flag alone, so
          // a null handler by itself looks live and reads as a broken click.
          enabled: _canConnect,
          onPressed: _canConnect ? _connect : null,
          child: Text(_connecting ? 'Connecting…' : 'Connect'),
        ),
      ],
      // Stacked, not side by side: the key is long and the provider name is
      // short, so a row would give the field that matters the least room. The
      // placeholders name both fields, so headings above them would only repeat
      // themselves.
      child: DialogBody(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (available.isEmpty)
              Text(
                'Every provider App Studio knows about already has a key.',
                style: theme.textTheme.muted,
              )
            else
              ShadSelect<String>(
                enabled: !_connecting,
                initialValue: _providerId,
                placeholder: const Text('Select provider'),
                options: [
                  for (final p in available)
                    ShadOption(value: p.id, child: Text(p.label)),
                ],
                selectedOptionBuilder: (context, value) => Text(
                  curatedProviders
                      .firstWhere(
                        (p) => p.id == value,
                        orElse: () => CuratedProvider(id: value, label: value),
                      )
                      .label,
                ),
                onChanged: (value) => setState(() => _providerId = value),
              ),
            const ShadGap(2),
            ShadInput(
              controller: _keyController,
              obscureText: true,
              enabled: !_connecting,
              placeholder: const Text('Paste the API key…'),
              onSubmitted: (_) => _connect(),
            ),
            if (_error case final error?) ...[
              const ShadGap(3),
              ErrorBanner(message: error),
            ],
          ],
        ),
      ),
    );
  }
}
