import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../theme/app_theme.dart';
import '../../toolchain/tool_status.dart';
import '../../uninstall/uninstall_result.dart';
import '../../util/byte_format.dart';

/// Matches the sibling dialogs. Shad caps a dialog at 512 anyway, so this only
/// has to be wide enough not to shrink the content below that.
const _kDialogWidth = 520.0;

/// Tools that cannot stay when [id] goes. Removing Flutter removes the Dart
/// the Serverpod CLI runs on, so the CLI would be left unable to start.
const kUninstallRequires = <ToolId, Set<ToolId>>{
  ToolId.flutter: {ToolId.serverpodCli},
};

/// [picked] plus everything removing it takes with it, limited to [offered].
Set<ToolId> effectiveUninstallSelection(
  Set<ToolId> picked,
  Iterable<ToolId> offered,
) {
  final result = {...picked};
  for (final id in picked) {
    result.addAll(kUninstallRequires[id] ?? const {});
  }
  return result.intersection(offered.toSet());
}

/// What removing each tool does to everything else on the Mac.
String uninstallConsequence(ToolId id) => switch (id) {
      ToolId.serverpodCli =>
        'Runs dart uninstall serverpod_cli and deletes ~/.serverpod, '
            'including your Serverpod Cloud login.',
      ToolId.flutter =>
        'Deletes the Flutter SDK and its PATH line. Other Flutter projects on '
            'this Mac will stop building.',
      ToolId.commandLineTools =>
        'Removes git, compilers and the other command line developer tools. '
            'Homebrew and anything else that builds code on this Mac may stop '
            'working. Asks for your administrator password.',
    };

Future<UninstallChoice?> showUninstallConfirmDialog(
  BuildContext context, {
  required Future<int?> Function() measureBytes,
  required List<ToolId> removableTools,
}) {
  return showShadDialog<UninstallChoice>(
    context: context,
    // A stray click on the barrier must not throw away the decision — Cancel
    // is the way out.
    barrierDismissible: false,
    builder: (context) => UninstallConfirmDialog(
      measureBytes: measureBytes,
      removableTools: removableTools,
    ),
  );
}

/// Confirms an uninstall, naming exactly what goes and what stays.
///
/// App Studio's own data — its Application Support folder and preferences —
/// always goes, so a relaunch behaves like a fresh install. The tools it
/// installed are real installs that other things may now depend on, so each
/// is a checkbox, ticked, with what removing it would break written under it.
class UninstallConfirmDialog extends StatefulWidget {
  const UninstallConfirmDialog({
    super.key,
    required this.measureBytes,
    this.removableTools = const [],
  });

  /// Size of App Studio's own data, or null if it could not be measured.
  /// Injected rather than shelled out to here: `du` is `dart:io`, and this
  /// dialog has to stay renderable in previews.
  final Future<int?> Function() measureBytes;

  /// Tools App Studio installed that are still here, in removal order.
  final List<ToolId> removableTools;

  @override
  State<UninstallConfirmDialog> createState() => _UninstallConfirmDialogState();
}

class _UninstallConfirmDialogState extends State<UninstallConfirmDialog> {
  bool _clearPubCache = false;
  late Set<ToolId> _picked = widget.removableTools.toSet();
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

  Set<ToolId> get _selection =>
      effectiveUninstallSelection(_picked, widget.removableTools);

  /// Ticked because something else that is ticked needs it gone.
  bool _forced(ToolId id) =>
      _selection.contains(id) &&
      _picked.any((other) => kUninstallRequires[other]?.contains(id) ?? false);

  @override
  Widget build(BuildContext context) {
    final selection = _selection;

    // The alert variant is the one with no close X — Cancel is the way out.
    return ShadDialog.alert(
      title: const Text('Uninstall App Studio'),
      // The lead paragraph belongs in `description`, which resolves to shad's
      // body role. Set in `textTheme.small` it picked up the *label* style —
      // `font-medium leading-none` — and read bold and cramped.
      description: Text(
        'This removes all App Studio settings and data'
        '${_supportBytes == null ? '' : ' (${formatBytes(_supportBytes!)})'}'
        '${widget.removableTools.isEmpty ? '' : ', and the tools you tick below'}'
        '. The app itself is not deleted, drag it to the Trash afterwards.',
      ),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ShadButton.destructive(
          onPressed: () => Navigator.of(context).pop(
            UninstallChoice(tools: selection, clearPubCache: _clearPubCache),
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
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final id in widget.removableTools) ...[
              ShadCheckbox(
                value: selection.contains(id),
                enabled: !_forced(id),
                onChanged: (v) => setState(() {
                  _picked = v ? {..._picked, id} : ({..._picked}..remove(id));
                }),
                label: Text(
                  'Uninstall ${id.displayName}',
                  style: kWeightMedium,
                ),
                sublabel: Text(
                  _forced(id)
                      ? '${uninstallConsequence(id)} Required when removing '
                          '${_requiredBy(id)}.'
                      : uninstallConsequence(id),
                ),
              ),
              const ShadGap(3),
            ],
            ShadCheckbox(
              value: _clearPubCache,
              onChanged: (v) => setState(() => _clearPubCache = v),
              label: Text(
                'Also clear the Dart package cache',
                style: kWeightMedium,
              ),
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

  String _requiredBy(ToolId id) => [
        for (final other in _picked)
          if (kUninstallRequires[other]?.contains(id) ?? false)
            other.displayName,
      ].join(' and ');
}
