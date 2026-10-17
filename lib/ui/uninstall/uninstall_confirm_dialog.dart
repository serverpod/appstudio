import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../theme/app_theme.dart';
import '../../toolchain/tool_status.dart';
import '../../uninstall/uninstall_result.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/dialog_body.dart';

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

/// What removing a tool does to everything else on the machine, where that is
/// worth saying. Flutter and Serverpod say nothing: removing them is what the
/// checkbox label already says.
String? uninstallConsequence(ToolId id) => switch (id) {
      ToolId.commandLineTools =>
        'Removes git, compilers, and the other command line developer tools. '
            'If other apps use them, they may be affected.',
      ToolId.developerMode =>
        'Other developer tools on this PC may rely on Developer Mode.',
      ToolId.git => 'Other apps and terminals that use git may be affected.',
      ToolId.flutter || ToolId.serverpodCli => null,
    };

Future<UninstallChoice?> showUninstallConfirmDialog(
  BuildContext context, {
  required List<ToolId> removableTools,
}) {
  return showAppDialog<UninstallChoice>(
    context: context,
    // A stray click on the barrier must not throw away the decision — Cancel
    // is the way out.
    barrierDismissible: false,
    builder: (context) =>
        UninstallConfirmDialog(removableTools: removableTools),
  );
}

/// Confirms an uninstall.
///
/// App Studio's own data — its Application Support folder and preferences —
/// always goes, so a relaunch behaves like a fresh install. The tools it
/// installed are real installs that other things may now depend on, so each
/// is a checkbox, ticked — except Developer Mode, a Windows setting other
/// tools may rely on, which starts unticked. Removing Flutter also clears the Dart package cache;
/// with Flutter staying, the cache is left alone.
class UninstallConfirmDialog extends StatefulWidget {
  const UninstallConfirmDialog({super.key, this.removableTools = const []});

  /// Tools App Studio installed that are still here, in removal order.
  final List<ToolId> removableTools;

  @override
  State<UninstallConfirmDialog> createState() => _UninstallConfirmDialogState();
}

class _UninstallConfirmDialogState extends State<UninstallConfirmDialog> {
  late Set<ToolId> _picked = widget.removableTools.toSet()
    ..removeAll(kUninstallUntickedByDefault);

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
      description: Text(
        'Uninstall the selected components. Afterward, you can '
        '$removeAppAfterward.',
      ),
      actions: [
        ShadButton.outline(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ShadButton.destructive(
          onPressed: () =>
              Navigator.of(context).pop(UninstallChoice(tools: selection)),
          child: const Text('Uninstall'),
        ),
      ],
      child: SizedBox(
        // The narrow-screen fallback — full-width stacked buttons, *reversed*,
        // which puts the destructive "Uninstall" above "Cancel" as if it were
        // the safe default — keys off the 640 **screen** breakpoint, not this
        // width. Nothing here can prevent it; this only sets content width.
        width: _kDialogWidth,
        child: DialogBody(
          child: widget.removableTools.isEmpty ? null : _toolList(selection),
        ),
      ),
    );
  }

  /// One ticked checkbox per tool App Studio installed.
  Widget _toolList(Set<ToolId> selection) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (index, id) in widget.removableTools.indexed) ...[
            if (index > 0) const ShadGap(3),
            ShadCheckbox(
              value: selection.contains(id),
              enabled: !_forced(id),
              onChanged: (v) => setState(() {
                _picked = v ? {..._picked, id} : ({..._picked}..remove(id));
              }),
              label: Text(
                // A setting is turned off, not uninstalled.
                id == ToolId.developerMode
                    ? 'Turn off ${id.displayName}'
                    : 'Uninstall ${id.displayName}',
                style: kWeightMedium,
              ),
              sublabel: _sublabel(id),
            ),
          ],
        ],
      );

  /// A disabled box needs its reason; otherwise only the tools whose removal
  /// reaches past App Studio carry a line.
  Widget? _sublabel(ToolId id) {
    if (_forced(id)) return Text('Required when removing ${_requiredBy(id)}.');
    return switch (uninstallConsequence(id)) {
      final consequence? => Text(consequence),
      null => null,
    };
  }

  String _requiredBy(ToolId id) => [
        for (final other in _picked)
          if (kUninstallRequires[other]?.contains(id) ?? false)
            other.displayName,
      ].join(' and ');
}
