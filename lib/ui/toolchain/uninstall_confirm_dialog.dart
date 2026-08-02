import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../toolchain/tool_status.dart';
import '../../toolchain/toolchain_controller.dart';
import '../../util/byte_format.dart';
import '../../util/pretty_path.dart';

/// What the user agreed to remove.
class UninstallChoice {
  const UninstallChoice({required this.clearPubCache});

  /// Also run `dart pub cache clean`, which affects every Dart project on the
  /// machine — never implied by "uninstall all tools".
  final bool clearPubCache;
}

Future<UninstallChoice?> showUninstallConfirmDialog(
  BuildContext context, {
  required ToolchainController toolchains,
}) {
  return showShadDialog<UninstallChoice>(
    context: context,
    builder: (context) => UninstallConfirmDialog(toolchains: toolchains),
  );
}

/// Confirms removal of everything managed, naming the exact size.
///
/// The Dart package cache is offered separately and off by default: it is
/// shared with every other Dart project on the machine and holds
/// `dart install`-ed global packages, so it is re-downloadable but not ours.
class UninstallConfirmDialog extends StatefulWidget {
  const UninstallConfirmDialog({super.key, required this.toolchains});

  final ToolchainController toolchains;

  @override
  State<UninstallConfirmDialog> createState() => _UninstallConfirmDialogState();
}

class _UninstallConfirmDialogState extends State<UninstallConfirmDialog> {
  bool _clearPubCache = false;
  int? _managedBytes;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final root = widget.toolchains.paths.toolchainRoot;
    try {
      final result = await Process.run('/usr/bin/du', ['-sk', root]);
      if (result.exitCode != 0) return;
      final kb = int.tryParse(
        (result.stdout as String).trim().split(RegExp(r'\s+')).first,
      );
      if (kb != null && mounted) setState(() => _managedBytes = kb * 1024);
    } catch (_) {
      // Size is a nicety; the dialog works without it.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final toolchains = widget.toolchains;
    final managed = [
      for (final status in toolchains.inventory.tools.values)
        if (status.resolved?.source == ToolSource.managed) status,
    ];

    return ShadDialog(
      title: const Text('Uninstall all tools'),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ShadButton.destructive(
          onPressed: () => Navigator.of(context).pop(
            UninstallChoice(clearPubCache: _clearPubCache),
          ),
          child: const Text('Uninstall'),
        ),
      ],
      child: SizedBox(
        width: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              managed.isEmpty
                  ? 'This removes the App Studio toolchain folder. Tools '
                      'already on your Mac are not touched.'
                  : 'This removes ${managed.length} managed '
                      '${managed.length == 1 ? 'tool' : 'tools'}'
                      '${_managedBytes == null ? '' : ' (${formatBytes(_managedBytes!)})'}'
                      '. Tools already on your Mac are not touched.',
              style: theme.textTheme.small,
            ),
            const SizedBox(height: 8),
            Text(
              prettyPath(toolchains.paths.toolchainRoot),
              style: theme.textTheme.muted.copyWith(fontSize: 11),
            ),
            const SizedBox(height: 14),
            _CheckRow(
              value: _clearPubCache,
              onChanged: (v) => setState(() => _clearPubCache = v),
              title: 'Also clear the Dart package cache',
              subtitle:
                  'Runs "dart pub cache clean". This cache is shared with every '
                  'Dart project on your Mac, not just App Studio.',
            ),
          ],
        ),
      ),
    );
  }
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({
    required this.value,
    required this.onChanged,
    required this.title,
    required this.subtitle,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ShadCheckbox(value: value, onChanged: onChanged),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.small),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: theme.textTheme.muted.copyWith(fontSize: 11),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
