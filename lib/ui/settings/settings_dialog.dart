import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../util/byte_format.dart';
import '../toolchain/tools_view.dart';
import 'providers_view.dart';
import '../toolchain/manage_tools_pane.dart';
import 'providers_settings_pane.dart';

/// Which pane to open on.
enum SettingsTab { providers, tools }

const _kDialogWidth = 580.0;
const _kDialogMaxHeight = 520.0;

Future<void> showSettingsDialog(
  BuildContext context, {
  required ProvidersView agent,
  required ToolsView toolchains,
  SettingsTab initialTab = SettingsTab.providers,
}) {
  return showShadDialog<void>(
    context: context,
    builder: (context) => SettingsDialog(
      agent: agent,
      toolchains: toolchains,
      initialTab: initialTab,
    ),
  );
}

/// One window for everything configurable: AI providers and the toolchain.
///
/// They were separate dialogs, reachable from unrelated menus, which made
/// "where do I change that?" a guessing game. Tabs keep each pane's content
/// intact while giving them one home.
class SettingsDialog extends StatefulWidget {
  const SettingsDialog({
    super.key,
    required this.agent,
    required this.toolchains,
    this.initialTab = SettingsTab.providers,
  });

  final ProvidersView agent;
  final ToolsView toolchains;
  final SettingsTab initialTab;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late SettingsTab _tab = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    // Listened to inline rather than with addListener + setState: the tools
    // pane starts a deep probe from its initState, which notifies during this
    // dialog's own build. A setState there is a "called during build" crash.
    return ListenableBuilder(
      listenable: widget.toolchains,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final installing = widget.toolchains.isInstalling;

    return ShadDialog(
      title: const Text('Settings'),
      // Cancelling mid-install is offered inline in the tools pane; closing the
      // dialog would leave a download running with nowhere to report.
      closeIcon: installing ? const SizedBox.shrink() : null,
      actions: [
        if (_tab == SettingsTab.tools) ?_installAction(),
        ShadButton.outline(
          onPressed: installing ? null : () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
      child: SizedBox(
        width: _kDialogWidth,
        child: ShadTabs<SettingsTab>(
          value: _tab,
          // Shad defaults to intrinsic-width tabs; ours are a two-up
          // segmented control that has to fill the dialog width.
          expandTabs: true,
          onChanged: (value) => setState(() => _tab = value),
          tabs: [
            ShadTab(
              value: SettingsTab.providers,
              content: _paneBox(ProvidersSettingsPane(agent: widget.agent)),
              child: const Text('Providers'),
            ),
            ShadTab(
              value: SettingsTab.tools,
              content: _paneBox(
                ManageToolsPane(toolchains: widget.toolchains),
              ),
              child: const Text('Tools'),
            ),
          ],
        ),
      ),
    );
  }

  /// The footer's install button. Lives here rather than in the pane so the
  /// dialog owns all of its own chrome.
  Widget? _installAction() {
    final toolchains = widget.toolchains;
    final installable = toolchains.inventory.installable;
    if (installable.isEmpty || toolchains.isInstalling) return null;
    return ShadButton(
      onPressed: toolchains.isBusy ? null : toolchains.installMissing,
      child: Text(
        'Install ${installable.length == 1 ? '1 tool' : '${installable.length} tools'} '
        '(${formatBytes(toolchains.inventory.downloadBytes)})',
      ),
    );
  }

  /// Both panes scroll internally, so the box only has to stop the dialog from
  /// growing past the screen. A fixed height would leave the shorter pane with
  /// dead space, so this caps rather than sets.
  Widget _paneBox(Widget child) => ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: _kDialogMaxHeight),
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: child,
        ),
      );
}
