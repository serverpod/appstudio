import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../util/byte_format.dart';

/// Matches the sibling dialogs. Shad caps a dialog at 512 anyway, so this only
/// has to be wide enough not to shrink the content below that.
const _kDialogWidth = 520.0;

/// What the user agreed to remove.
class UninstallChoice {
  const UninstallChoice({required this.clearPubCache});

  /// Also run `dart pub cache clean`, which affects every Dart project on the
  /// machine — never implied by "uninstall all tools".
  final bool clearPubCache;
}

Future<UninstallChoice?> showUninstallConfirmDialog(
  BuildContext context, {
  required String supportRootLabel,
  required Future<int?> Function() measureBytes,
}) {
  return showShadDialog<UninstallChoice>(
    context: context,
    builder: (context) => UninstallConfirmDialog(
      supportRootLabel: supportRootLabel,
      measureBytes: measureBytes,
    ),
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
  const UninstallConfirmDialog({
    super.key,
    required this.supportRootLabel,
    required this.measureBytes,
  });

  /// Already shortened for display.
  final String supportRootLabel;

  /// Total size on disk, or null if it could not be measured. Injected rather
  /// than shelled out to here: `du` is `dart:io`, and this dialog has to stay
  /// renderable in previews and golden tests.
  final Future<int?> Function() measureBytes;

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
    // Size is a nicety; the dialog works without it.
    final bytes = await widget.measureBytes();
    if (bytes != null && mounted) setState(() => _supportBytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);

    return ShadDialog(
      title: const Text('Uninstall App Studio'),
      // The lead paragraph belongs in `description`, which resolves to shad's
      // body role. Set in `textTheme.small` it picked up the *label* style —
      // `font-medium leading-none` — and read bold and cramped.
      description: Text(
        'This removes the downloaded tools, the shell PATH entry and all '
        'App Studio settings'
        '${_supportBytes == null ? '' : ' (${formatBytes(_supportBytes!)})'}'
        '. The app itself is not deleted — you can drag it to the Trash '
        'afterwards.',
      ),
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
        // The narrow-screen fallback — full-width stacked buttons, *reversed*,
        // which puts the destructive "Uninstall" above "Cancel" as if it were
        // the safe default — keys off the 640 **screen** breakpoint, not this
        // width. Nothing here can prevent it; this only sets content width.
        width: _kDialogWidth,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.supportRootLabel,
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
            ShadCheckbox(
              value: _clearPubCache,
              onChanged: (v) => setState(() => _clearPubCache = v),
              label: const Text('Also clear the Dart package cache'),
              sublabel: const Text(
                'Runs "dart pub cache clean". This cache is shared with every '
                'Dart project on your Mac, not just App Studio.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
