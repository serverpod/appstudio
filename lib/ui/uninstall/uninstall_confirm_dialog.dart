import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

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

/// Confirms a full uninstall, naming exactly what goes and what stays.
///
/// This is a bigger action than the old "uninstall all tools": it removes the
/// whole Application Support directory, the shell PATH entry and every stored
/// preference, so that a relaunch behaves like a fresh install.
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
  int? _supportBytes;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final root = widget.toolchains.paths.appSupportRoot;
    try {
      final result = await Process.run('/usr/bin/du', ['-sk', root]);
      if (result.exitCode != 0) return;
      final kb = int.tryParse(
        (result.stdout as String).trim().split(RegExp(r'\s+')).first,
      );
      if (kb != null && mounted) setState(() => _supportBytes = kb * 1024);
    } catch (_) {
      // Size is a nicety; the dialog works without it.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final toolchains = widget.toolchains;

    return ShadDialog(
      title: const Text('Uninstall App Studio'),
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
              'This removes the downloaded tools, the shell PATH entry and all '
              'App Studio settings'
              '${_supportBytes == null ? '' : ' (${formatBytes(_supportBytes!)})'}'
              '. The app itself is not deleted — you can drag it to the Trash '
              'afterwards.',
              style: theme.textTheme.small,
            ),
            const SizedBox(height: 8),
            Text(
              prettyPath(toolchains.paths.appSupportRoot),
              style: theme.textTheme.muted.copyWith(fontSize: 11),
            ),
            const SizedBox(height: 10),
            // Say what survives, so nobody has to guess whether their API keys
            // or every other Dart project just went with it.
            Text(
              'Tools already on your Mac, your Dart package cache and your '
              'OpenCode API keys are left alone. The keys are shared with the '
              'OpenCode CLI, so removing them here would affect more than App '
              'Studio.',
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
