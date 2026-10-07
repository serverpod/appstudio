import 'package:flutter/material.dart';
import 'package:shad/shad.dart';

import '../agent/agent_controller.dart';
import '../feature_flags.dart';
import '../process/serverpod_process.dart';
import '../runner/runner_log.dart';
import '../theme/app_theme.dart';
import '../widgets/text_segmented_control.dart';
import 'agent/agent_pane.dart';
import 'server_log/server_log_view.dart';

/// A tab in the left panel: the agent, the server log, or a Flutter app's log.
sealed class LeftPaneTab {
  const LeftPaneTab();

  static const agent = AgentTab();
  static const server = LogTab(ServerLogSource());
}

final class AgentTab extends LeftPaneTab {
  const AgentTab();

  @override
  bool operator ==(Object other) => other is AgentTab;

  @override
  int get hashCode => 1;
}

final class LogTab extends LeftPaneTab {
  const LogTab(this.source);

  final LogSource source;

  @override
  bool operator ==(Object other) => other is LogTab && other.source == source;

  @override
  int get hashCode => source.hashCode;
}

/// The tabs for the runner's current Flutter apps, after the server's.
List<TextSegment<LeftPaneTab>> leftPaneTabs(RunnerLog log) => [
      if (kOpenCodeAgentEnabled)
        const TextSegment(value: LeftPaneTab.agent, label: 'Agent'),
      const TextSegment(value: LeftPaneTab.server, label: 'Server'),
      for (final app in log.apps)
        TextSegment(value: LogTab(AppLogSource(app.id)), label: app.name),
    ];

/// The panel left of the preview: the agent (when switched on) and the logs —
/// the server's, and one per Flutter app the runner knows about.
class LeftPane extends StatefulWidget {
  const LeftPane({
    super.key,
    required this.agent,
    required this.process,
  });

  final AgentController agent;
  final ServerpodProcessController process;

  @override
  State<LeftPane> createState() => _LeftPaneState();
}

class _LeftPaneState extends State<LeftPane> {
  /// With the agent switched off, the server log is the first tab — starting
  /// on the agent would show a pane that is no longer reachable.
  LeftPaneTab _selected =
      kOpenCodeAgentEnabled ? LeftPaneTab.agent : LeftPaneTab.server;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    final process = widget.process;

    return ListenableBuilder(
      listenable: process.log,
      builder: (context, _) {
        final tabs = leftPaneTabs(process.log);
        // An app the runner dropped takes its tab with it.
        final selected = tabs.any((tab) => tab.value == _selected)
            ? _selected
            : LeftPaneTab.server;
        final source = switch (selected) {
          LogTab(:final source) => source,
          AgentTab() => const ServerLogSource(),
        };
        final logView = ServerLogView(
          log: process.log,
          actions: process,
          source: source,
          emptyMessage: switch (process.state) {
            ProcessState.starting => 'Waiting for the server to start…',
            ProcessState.idle => 'The server is not running.',
            _ => null,
          },
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LeftPaneHeader(
              tabs: tabs,
              selected: selected,
              onChanged: (tab) => setState(() => _selected = tab),
            ),
            Expanded(
              child: ColoredBox(
                color: scheme.background,
                // The stack keeps the agent's scroll position across a switch.
                // With the agent off there is nothing to keep.
                child: kOpenCodeAgentEnabled
                    ? IndexedStack(
                        index: selected is AgentTab ? 0 : 1,
                        sizing: StackFit.expand,
                        children: [
                          AgentPane(
                            controller: widget.agent,
                            process: process,
                          ),
                          logView,
                        ],
                      )
                    : logView,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The left panel's header: one tab per log, plus the agent when it is on.
class LeftPaneHeader extends StatelessWidget {
  const LeftPaneHeader({
    super.key,
    required this.tabs,
    required this.selected,
    required this.onChanged,
  });

  final List<TextSegment<LeftPaneTab>> tabs;
  final LeftPaneTab selected;
  final ValueChanged<LeftPaneTab> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    return Container(
      height: kPaneHeaderHeight,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: scheme.muted,
        border: Border(bottom: paneBorderSide(scheme.border)),
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        // A project with several apps can outgrow the panel's minimum width.
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: TextSegmentedControl<LeftPaneTab>(
            value: selected,
            onChanged: onChanged,
            // One segment left, so there is nothing to switch to. Drawn the
            // same way the preview pane draws its own header label rather
            // than as plain text, so the two pane headers still match.
            interactive: tabs.length > 1,
            onMutedSurface: true,
            segments: tabs,
          ),
        ),
      ),
    );
  }
}
