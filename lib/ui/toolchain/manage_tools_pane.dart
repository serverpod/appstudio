import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../theme/app_theme.dart';
import '../../toolchain/install_progress.dart';
import '../../toolchain/shell_path_state.dart';
import '../../toolchain/tool_status.dart';
import '../../widgets/determinate_progress.dart';
import '../../widgets/error_banner.dart';
import '../../widgets/settings_table.dart';
import 'install_globally_checkbox.dart';
import 'tools_view.dart';

/// Which tools are in play, which version, and what can be done about them.
///
/// A pane inside the Settings dialog, so it owns no chrome of its own — the
/// install button lives in the dialog's footer.
///
/// Deliberately the same [ToolTable] first-run setup shows. This used to be a
/// stack of cards carrying a requirement line, an install path and per-tool
/// buttons, which answered questions nobody was asking and made the same
/// toolchain look like two different things depending on which screen you
/// reached it from.
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
      // Pulls a newer published manifest, which is the only way a managed
      // install can turn out to be behind — without it "Update All" could
      // never light up.
      unawaited(widget.toolchains.preflight());
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
    final toolchains = widget.toolchains;
    final inventory = toolchains.inventory;
    final missing = inventory.missingRequired;
    final updatable = inventory.updatable;
    final busy = toolchains.isBusy;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'App Studio uses these tools to create and run Serverpod projects.',
            style: theme.textTheme.muted,
          ),
          const ShadGap(3),
          if (toolchains.installError case final error?) ...[
            ErrorBanner(message: error),
            const ShadGap(3),
          ] else if (missing.isNotEmpty && !toolchains.isInstalling) ...[
            ErrorBanner(message: _missingMessage(missing)),
            const ShadGap(3),
          ],
          if (toolchains.progress case final progress?
              when toolchains.isInstalling) ...[
            _InstallBanner(
              progress: progress,
              onCancel: toolchains.cancelInstall,
            ),
            const ShadGap(3),
          ],
          SettingsTable(
            rows: [
              for (final id in ToolId.values)
                if (inventory[id] case final status?)
                  _rowFor(theme, status),
            ],
          ),
          const ShadGap(3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _ShellPathToggle(
                  toolchains: toolchains,
                  alreadyGlobal: inventory.requiredToolsAreNative,
                ),
              ),
              const ShadGap(2),
              Builder(
                builder: (context) {
                  // Disabled rather than hidden: "is there anything newer?" is a
                  // question the tab should answer even when the answer is no.
                  final canUpdate = !busy && updatable.isNotEmpty;
                  return ShadButton.outline(
                    // `enabled` as well as `onPressed`. shad dims from
                    // `ShadButton.enabled`, which defaults to true — a null
                    // `onPressed` alone makes a button inert while it still looks
                    // live, which is worse than either state on its own.
                    enabled: canUpdate,
                    onPressed: canUpdate
                        ? () => unawaited(
                              toolchains.install(
                                [for (final t in updatable) t.id],
                              ),
                            )
                        : null,
                    child: const Text('Update All'),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// The version in play, then what it means: where a usable copy came from, or
  /// that there is not one.
  SettingsTableRow _rowFor(ShadThemeData theme, ToolStatus status) {
    final resolved = status.resolved;
    final rejected = status.bestRejected;
    final pinned = status.spec.version;
    final installed = resolved?.detectedVersion;
    final isBehind = resolved != null &&
        resolved.source == ToolSource.managed &&
        installed != null &&
        installed < pinned;

    return SettingsTableRow(
      name: status.spec.displayName,
      // For anything usable, the version that is actually there. For a tool we
      // cannot run, the one we would install, with the rejected copy beside it.
      badge: versionBadge(
        resolved != null ? (isBehind ? pinned : installed!) : pinned,
        replacing: resolved != null
            ? (isBehind ? installed : null)
            : rejected?.detectedVersion,
      ),
      trailing: switch (resolved) {
        // `success`/`warning` ride in the scheme's custom map; there is no
        // shadcn token for either.
        final r? => appSuccessBadge(theme, child: Text(r.source.label)),
        null => appWarningBadge(theme, child: const Text('Missing')),
      },
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

    return ShadCard(
      backgroundColor: scheme.muted,
      title: Text('${active.phase.label} ${active.id.displayName}…'),
      action: ShadButton.ghost(
        onPressed: onCancel,
        child: const Text('Cancel'),
      ),
      child: DeterminateProgress(
        fraction: progress.fraction,
        caption: formatTransferCaption(
          received: progress.bytesReceived,
          total: progress.bytesTotal,
          eta: progress.eta,
        ),
      ),
    );
  }
}

/// Opt-in for putting the tools on the user's own `PATH`.
class _ShellPathToggle extends StatefulWidget {
  const _ShellPathToggle({
    required this.toolchains,
    this.alreadyGlobal = false,
  });

  final ToolsView toolchains;

  /// The tools are reachable outside App Studio without our help.
  final bool alreadyGlobal;

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

    // The "do it yourself" instructions are for a shell we cannot edit. With
    // the tools already reachable there is nothing to instruct.
    if (state == ShellPathState.unsupported && !widget.alreadyGlobal) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Install tools globally',
            style: theme.textTheme.small.semibold,
          ),
          const ShadGap(1),
          Text(
            'App Studio cannot edit ${widget.toolchains.shellName} configuration. '
            'Add this line yourself:',
            style: theme.textTheme.muted,
          ),
          const ShadGap(1.5),
          SelectableText(
            widget.toolchains.shellExportLine,
            style: theme.textTheme.muted.copyWith(fontFamily: kMacMonoFont),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InstallGloballyCheckbox(
          value: widget.alreadyGlobal || state == ShellPathState.present,
          enabled: !widget.alreadyGlobal,
          onChanged: _working ? null : (v) => _set(v),
        ),
        // Our block is not in play, so neither are the states that report on it.
        if (!widget.alreadyGlobal && state == ShellPathState.edited) ...[
          const SizedBox(height: 8),
          ErrorBanner(
            message:
                'Your shell config was edited inside the App Studio '
                'block, so it was left alone.',
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              ShadButton.outline(
                onPressed: _working ? null : () => _set(false),
                child: const Text('Remove it'),
              ),
              const SizedBox(width: 6),
              ShadButton.ghost(
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
