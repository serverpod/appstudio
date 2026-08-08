import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shad/shad.dart';

import '../../theme/app_theme.dart';
import '../../toolchain/install_progress.dart';
import '../../toolchain/shell_path_state.dart';
import '../../toolchain/tool_status.dart';
import '../../widgets/determinate_progress.dart';
import '../../widgets/error_banner.dart';
import 'tool_row.dart';
import 'tools_view.dart';

/// Where every tool came from, whether it is usable, and what to do about it.
///
/// A pane inside the Settings dialog, so it owns no chrome of its own — the
/// install button lives in the dialog's footer.
class ManageToolsPane extends StatefulWidget {
  const ManageToolsPane({super.key, required this.toolchains});

  final ToolsView toolchains;

  @override
  State<ManageToolsPane> createState() => _ManageToolsPaneState();
}

class _ManageToolsPaneState extends State<ManageToolsPane> {
  @override
  void initState() {
    super.initState();
    widget.toolchains.addListener(_onToolchains);
    // Deferred to after the frame: refresh() notifies synchronously before its
    // first await, so starting it here marks any ancestor listening to the
    // controller dirty in the middle of its own build. Harmless while this was
    // a standalone dialog, a crash once the Settings dialog wrapped it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // The startup probe stops at the first satisfied candidate; this view
      // wants the alternatives too ("you also have a host Flutter").
      unawaited(widget.toolchains.refreshDeep());
      unawaited(widget.toolchains.refreshShellPathState());
    });
  }

  @override
  void dispose() {
    widget.toolchains.removeListener(_onToolchains);
    super.dispose();
  }

  void _onToolchains() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final toolchains = widget.toolchains;
    final inventory = toolchains.inventory;
    final missing = inventory.missingRequired;
    final busy = toolchains.isBusy;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'App Studio uses these tools to create and run Serverpod projects.',
            style: theme.textTheme.muted,
          ),
          const SizedBox(height: 14),
          if (toolchains.installError case final error?) ...[
            ErrorBanner(message: error),
            const SizedBox(height: 12),
          ] else if (missing.isNotEmpty &&
              !toolchains.isInstalling) ...[
            ErrorBanner(message: _missingMessage(missing)),
            const SizedBox(height: 12),
          ],
          if (toolchains.progress case final progress?
              when toolchains.isInstalling) ...[
            _InstallBanner(
              progress: progress,
              onCancel: toolchains.cancelInstall,
            ),
            const SizedBox(height: 12),
          ],
          for (final id in ToolId.values)
            if (inventory[id] case final status?) ...[
              ToolRow(
                status: status,
                requirement: toolchains.requirementLabel(status.spec),
                progress: toolchains.progress?[id],
                actions: _actionsFor(status, busy),
              ),
              const SizedBox(height: 10),
            ],
          Divider(color: scheme.border, height: 1),
          const SizedBox(height: 12),
          _ShellPathToggle(toolchains: toolchains),
          const SizedBox(height: 12),
          Divider(color: scheme.border, height: 1),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  toolchains.toolchainRootLabel,
                  style: theme.textTheme.muted.copyWith(fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: () =>
                    unawaited(toolchains.revealToolchainFolder()),
                child: const Text('Reveal'),
              ),
              ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed:
                    busy ? null : toolchains.refreshDeep,
                child: Text(
                  toolchains.isRefreshing ? 'Checking…' : 'Re-check',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _missingMessage(List<ToolStatus> missing) {
    final unavailable = missing.where((t) => !t.canInstall).toList();
    if (unavailable.length == missing.length && unavailable.isNotEmpty) {
      // Nothing published for this Mac — say so rather than offering a button
      // that cannot work.
      return missing.length == 1
          ? '${missing.single.spec.displayName} is missing and is not '
              'available for download on this Mac.'
          : '${missing.length} tools are missing and are not available for '
              'download on this Mac.';
    }
    return missing.length == 1
        ? '${missing.single.spec.displayName} is missing. Some features will '
            'not work until it is installed.'
        : '${missing.length} tools are missing. Some features will not work '
            'until they are installed.';
  }

  List<Widget> _actionsFor(ToolStatus status, bool busy) {
    final toolchains = widget.toolchains;
    final resolved = status.resolved;
    final isManaged = resolved?.source == ToolSource.managed;
    final rejected = status.bestRejected;

    return [
      if (!status.isSatisfied && status.canInstall)
        ShadButton(
          size: ShadButtonSize.sm,
          onPressed: busy ? null : () => toolchains.install([status.id]),
          child: const Text('Install'),
        ),
      // A too-old host tool is theirs to upgrade, not ours to overwrite.
      if (rejected != null &&
          rejected.source == ToolSource.host &&
          rejected.fitness == ToolFitness.wrongVersion &&
          toolchains.upgradeCommand(status.id) != null) ...[
        const SizedBox(width: 6),
        _UpgradeHint(command: toolchains.upgradeCommand(status.id)!),
      ],
      if (isManaged) ...[
        const SizedBox(width: 6),
        ShadButton.ghost(
          size: ShadButtonSize.sm,
          onPressed: busy ? null : () => toolchains.uninstall(status.id),
          child: const Text('Remove'),
        ),
      ],
    ];
  }

}

class _InstallBanner extends StatelessWidget {
  const _InstallBanner({required this.progress, required this.onCancel});

  final InstallProgress progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    final active = progress.tools.firstWhere(
      (t) => !t.phase.isTerminal,
      orElse: () => progress.tools.last,
    );

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
                    '${active.phase.label} ${active.id.displayName}…',
                    style: theme.textTheme.small
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                ShadButton.ghost(
                  size: ShadButtonSize.sm,
                  onPressed: onCancel,
                  child: const Text('Cancel'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            DeterminateProgress(
              fraction: progress.fraction,
              caption: formatTransferCaption(
                received: progress.bytesReceived,
                total: progress.bytesTotal,
                eta: progress.eta,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shows the command that upgrades a host install, with a copy button.
class _UpgradeHint extends StatefulWidget {
  const _UpgradeHint({required this.command});

  final String command;

  @override
  State<_UpgradeHint> createState() => _UpgradeHintState();
}

class _UpgradeHintState extends State<_UpgradeHint> {
  bool _copied = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.command));
    if (!mounted) return;
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ShadTooltip(
      builder: (context) => Text('Copy “${widget.command}”'),
      child: ShadButton.ghost(
        size: ShadButtonSize.sm,
        onPressed: _copy,
        child: Text(_copied ? 'Copied' : 'Upgrade yours'),
      ),
    );
  }
}

/// Opt-in switch for putting the tools on the user's own `PATH`.
class _ShellPathToggle extends StatefulWidget {
  const _ShellPathToggle({required this.toolchains});

  final ToolsView toolchains;

  @override
  State<_ShellPathToggle> createState() => _ShellPathToggleState();
}

class _ShellPathToggleState extends State<_ShellPathToggle> {
  String? _error;
  bool _working = false;

  Future<void> _set(bool enabled, {bool force = false}) async {
    setState(() {
      _working = true;
      _error = null;
    });
    final error = await widget.toolchains.setShellPathEnabled(
      enabled,
      force: force,
    );
    if (mounted) {
      setState(() {
        _working = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final state = widget.toolchains.shellPathState;

    if (state == ShellPathState.unsupported) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Add the tools to your PATH',
            style: theme.textTheme.small.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            'App Studio cannot edit ${widget.toolchains.shellName} configuration. '
            'Add this line yourself:',
            style: theme.textTheme.muted.copyWith(fontSize: 11),
          ),
          const SizedBox(height: 6),
          SelectableText(
            widget.toolchains.shellExportLine,
            style: theme.textTheme.muted.copyWith(
              fontFamily: kMacMonoFont,
              fontSize: 10.5,
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ShadSwitch(
              value: state == ShellPathState.present,
              onChanged: _working ? null : (v) => _set(v),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Add the tools to your PATH',
                    style: theme.textTheme.small
                        .copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'App Studio does not need this — it already finds the '
                    'tools. Turn it on so an external editor or AI agent can '
                    'find them too. Edits a fenced block in '
                    '${widget.toolchains.shellRcLabel}.',
                    style: theme.textTheme.muted.copyWith(fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (state == ShellPathState.edited) ...[
          const SizedBox(height: 8),
          ErrorBanner(
            message: 'Your shell config was edited inside the App Studio '
                'block, so it was left alone.',
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              ShadButton.outline(
                size: ShadButtonSize.sm,
                onPressed: _working ? null : () => _set(false),
                child: const Text('Remove it'),
              ),
              const SizedBox(width: 6),
              ShadButton.ghost(
                size: ShadButtonSize.sm,
                onPressed: _working ? null : () => _set(true, force: true),
                child: const Text('Replace (backs up first)'),
              ),
            ],
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 8),
          ErrorBanner(message: _error!),
        ],
      ],
    );
  }
}
