import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../../feature_flags.dart';
import '../../util/byte_format.dart';
import '../toolchain/tools_view.dart';
import 'providers_view.dart';
import '../toolchain/manage_tools_pane.dart';
import 'providers_settings_pane.dart';
import '../../widgets/app_dialog.dart';
import '../../widgets/dialog_body.dart';

/// Which pane to open on.
enum SettingsTab { providers, tools }

const _kDialogWidth = 580.0;

/// Fixed, not a maximum. Both panes scroll internally, so sizing to content
/// made the window jump every time a tab changed, a provider was added or a
/// tool finished installing. A steady frame with whitespace under a short pane
/// is the cheaper trade.
const _kPaneHeight = 460.0;

Future<void> showSettingsDialog(
  BuildContext context, {
  required ProvidersView agent,
  required ToolsView toolchains,
  SettingsTab initialTab = SettingsTab.providers,
}) {
  return showAppDialog<void>(
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
  /// Providers configures API keys for the OpenCode agent and nothing else, so
  /// with the agent switched off there is one pane left and it is Tools. The
  /// caller is coerced rather than trusted: the App menu's Settings item still
  /// asks for Providers, and that pane would otherwise sit on its
  /// "waiting for the agent" spinner forever.
  late SettingsTab _tab =
      kOpenCodeAgentEnabled ? widget.initialTab : SettingsTab.tools;

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

    // The alert variant, whose theme carries no `closeIconData` — Done is the
    // way out, and during an install it is the only one, since closing would
    // leave a download running with nowhere to report.
    return ShadDialog.alert(
      title: const Text('Settings'),
      actions: [
        if (_tab == SettingsTab.tools) ?_installAction(),
        ShadButton.outline(
          onPressed: installing ? null : () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
      child: DialogBody(
        child: SizedBox(
          width: _kDialogWidth,
          // A tab strip with one tab in it is a button that does nothing, so
          // with Providers gone the pane is shown on its own.
          child: kOpenCodeAgentEnabled
              ? ShadTabs<SettingsTab>(
                  value: _tab,
                  // Shad defaults to intrinsic-width tabs; ours are a two-up
                  // segmented control that has to fill the dialog width.
                  expandTabs: true,
                  onChanged: (value) => setState(() => _tab = value),
                  tabs: [
                    ShadTab(
                      value: SettingsTab.providers,
                      content: _paneBox(
                        ProvidersSettingsPane(agent: widget.agent),
                      ),
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
                )
              : _paneBox(ManageToolsPane(toolchains: widget.toolchains)),
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
    final bytes = toolchains.plan.covers([for (final t in installable) t.id])
        ? toolchains.plan.downloadBytes
        : 0;
    return ShadButton(
      enabled: !toolchains.isBusy,
      onPressed: toolchains.isBusy ? null : toolchains.installMissing,
      child: Text(
        'Install ${installable.length == 1 ? '1 tool' : '${installable.length} tools'}'
        '${bytes > 0 ? ' (${formatBytes(bytes)})' : ''}',
      ),
    );
  }

  /// Both panes scroll internally, so this only has to hold the frame still.
  Widget _paneBox(Widget child) => SizedBox(
        height: _kPaneHeight,
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: child,
        ),
      );
}
