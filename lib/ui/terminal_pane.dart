import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shad/shad.dart';
import 'package:xterm/xterm.dart';

import '../agent/agent_controller.dart';
import '../feature_flags.dart';
import '../process/serverpod_process.dart';
import '../terminal/studio_terminal.dart';
import '../theme/app_theme.dart';
import '../widgets/text_segmented_control.dart';
import 'agent/agent_pane.dart';

/// The left panel's tabs. With the agent switched off, only the server log.
enum TerminalPaneTab { agent, serverLogs }

/// Font size for the server log terminal. [terminalPaneMinWidth] measures with
/// it, so the panel's 80-column minimum follows a change here automatically.
const kTerminalFontSize = 11.0;

/// The terminal's content inset on every side.
const _kTerminalPadding = 8.0;

double? _cachedMinWidth;

/// Minimum width for the pane that keeps a full 80-column log line visible,
/// padding included.
///
/// Measured from the terminal's own font rather than hardcoded, so it cannot
/// drift when [kTerminalFontSize] or [kMacMonoFont] moves. Cached — the
/// metrics cannot change at runtime.
double terminalPaneMinWidth() => _cachedMinWidth ??= _measureMinWidth();

double _measureMinWidth() {
  final painter = TextPainter(
    text: TextSpan(
      text: ''.padRight(80, 'M'),
      style: const TextStyle(
        fontFamily: kMacMonoFont,
        fontSize: kTerminalFontSize,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final width = painter.width + 2 * _kTerminalPadding;
  painter.dispose();
  return width;
}

class TerminalPane extends StatefulWidget {
  const TerminalPane({
    super.key,
    required this.studioTerminal,
    required this.agent,
    required this.process,
  });

  final StudioTerminal studioTerminal;
  final AgentController agent;
  final ServerpodProcessController process;

  /// The terminal's palette.
  ///
  /// Chrome — cursor, selection, foreground, background — comes from the shad
  /// theme. The sixteen ANSI slots do not: they are the palette a program's
  /// escape codes address by index, so they are fixed values here rather than
  /// theme tokens that would shift under the program's feet.
  static TerminalTheme terminalTheme(ShadThemeData theme) {
    final isDark = theme.brightness == Brightness.dark;
    if (isDark) {
      return TerminalTheme(
        cursor: theme.colorScheme.foreground,
        selection: theme.colorScheme.selection.withValues(alpha: 0.35),
        foreground: theme.colorScheme.foreground,
        background: theme.colorScheme.background,
        black: const Color(0xFF1E293B),
        red: const Color(0xFFEF4444),
        green: const Color(0xFF22C55E),
        yellow: const Color(0xFFF59E0B),
        blue: kBrandBlue,
        magenta: const Color(0xFFA855F7),
        cyan: const Color(0xFF14B8A6),
        white: theme.colorScheme.foreground,
        brightBlack: theme.colorScheme.mutedForeground,
        brightRed: const Color(0xFFFCA5A5),
        brightGreen: const Color(0xFF86EFAC),
        brightYellow: const Color(0xFFFBBF24),
        brightBlue: const Color(0xFF93C5FD),
        brightMagenta: const Color(0xFFC4B5FD),
        brightCyan: const Color(0xFF5EEAD4),
        brightWhite: theme.colorScheme.foreground,
        searchHitBackground: const Color(0x66FBBF24),
        searchHitBackgroundCurrent: const Color(0x99F59E0B),
        searchHitForeground: theme.colorScheme.foreground,
      );
    }

    return TerminalTheme(
      cursor: theme.colorScheme.foreground,
      selection: theme.colorScheme.selection.withValues(alpha: 0.35),
      foreground: theme.colorScheme.foreground,
      background: theme.colorScheme.background,
      black: const Color(0xFF0F172A),
      red: const Color(0xFFEF4444),
      green: const Color(0xFF22C55E),
      yellow: const Color(0xFFF59E0B),
      blue: kBrandBlue,
      magenta: const Color(0xFF9333EA),
      cyan: const Color(0xFF0F766E),
      white: const Color(0xFF334155),
      brightBlack: theme.colorScheme.mutedForeground,
      brightRed: const Color(0xFFEF4444),
      brightGreen: const Color(0xFF10B981),
      brightYellow: const Color(0xFFF59E0B),
      brightBlue: const Color(0xFF3B82F6),
      brightMagenta: const Color(0xFFA855F7),
      brightCyan: const Color(0xFF14B8A6),
      brightWhite: theme.colorScheme.foreground,
      searchHitBackground: const Color(0x66FBBF24),
      searchHitBackgroundCurrent: const Color(0x99F59E0B),
      searchHitForeground: theme.colorScheme.foreground,
    );
  }

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  /// With the agent switched off there is only one tab, and the server log is
  /// it — starting on [TerminalPaneTab.agent] would show a pane that is no longer
  /// reachable.
  TerminalPaneTab _selectedTab =
      kOpenCodeAgentEnabled ? TerminalPaneTab.agent : TerminalPaneTab.serverLogs;

  @override
  Widget build(BuildContext context) {
    final scheme = ShadTheme.of(context).colorScheme;
    final showsAgent = kOpenCodeAgentEnabled;

    final terminal = ServerLogView(
      terminal: widget.studioTerminal.terminal,
      autofocus: _selectedTab == TerminalPaneTab.serverLogs,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TerminalPaneHeader(
          tab: _selectedTab,
          onChanged: (tab) => setState(() => _selectedTab = tab),
        ),
        Expanded(
          child: ColoredBox(
            color: scheme.background,
            // The stack is what keeps both alive across a switch — the agent's
            // scroll position and the xterm buffer survive it. With nothing to
            // switch between it is just overhead.
            child: showsAgent
                ? IndexedStack(
                    index: _selectedTab == TerminalPaneTab.agent ? 0 : 1,
                    sizing: StackFit.expand,
                    children: [
                      AgentPane(
                        controller: widget.agent,
                        process: widget.process,
                      ),
                      terminal,
                    ],
                  )
                : terminal,
          ),
        ),
      ],
    );
  }
}

/// What the server log answers from the keyboard: copying what is selected and
/// selecting everything.
///
/// ⌘V is listed in order to be refused, and leaving it out is not enough.
/// xterm puts a paste action above its focus node that writes the clipboard to
/// the PTY, and `ShadApp`'s default text-editing shortcuts map ⌘V to that
/// intent — so an unlisted ⌘V bubbles up to them and is pasted into the
/// running server anyway. Stopping propagation here still reports the key
/// unhandled, so the menu bar gets it like any other.
const _kServerLogShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.keyC, meta: true):
      CopySelectionTextIntent.copy,
  SingleActivator(LogicalKeyboardKey.keyA, meta: true):
      SelectAllTextIntent(SelectionChangedCause.keyboard),
  SingleActivator(LogicalKeyboardKey.keyV, meta: true):
      DoNothingAndStopPropagationIntent(),
};

/// The server log: an xterm showing what `serverpod start` prints.
///
/// **Output only.** It still takes focus, because ⌘C and ⌘A act on the focused
/// widget, but every other key has to come back out unhandled — a key Flutter
/// reports as handled never reaches the menu bar, so a log that swallowed keys
/// took ⌘W and every other menu shortcut with it for as long as it held focus,
/// which with autofocus is from the moment a project opens.
///
/// Two settings do that, and the second lives on the [Terminal]:
///
/// - `readOnly` with `hardwareKeyboardOnly` left *off*. On, xterm listens with
///   `CustomKeyboardListener`, which types any key it did not otherwise handle
///   into the terminal and reports it handled — ⌘W arrived at the server as a
///   `w`. Off, it uses the text-input path, which `readOnly` keeps from ever
///   opening an input connection, so nothing is inserted from there either.
/// - `inputHandler: null` on the terminal itself (see [StudioTerminal]).
///   `readOnly` does not stop xterm translating Enter, Tab, the arrows and
///   Ctrl chords into escape sequences for the PTY.
class ServerLogView extends StatelessWidget {
  const ServerLogView({
    super.key,
    required this.terminal,
    this.autofocus = false,
  });

  final Terminal terminal;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return TerminalView(
      terminal,
      theme: TerminalPane.terminalTheme(ShadTheme.of(context)),
      textStyle: const TerminalStyle(
        fontSize: kTerminalFontSize,
        fontFamily: kMacMonoFont,
      ),
      padding: const EdgeInsets.all(_kTerminalPadding),
      autofocus: autofocus,
      shortcuts: _kServerLogShortcuts,
      readOnly: true,
    );
  }
}

/// The left panel's header: its tabs, or with the agent switched off the one
/// label.
class TerminalPaneHeader extends StatelessWidget {
  const TerminalPaneHeader({
    super.key,
    required this.tab,
    required this.onChanged,
  });

  final TerminalPaneTab tab;
  final ValueChanged<TerminalPaneTab> onChanged;

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
        child: TextSegmentedControl<TerminalPaneTab>(
          value: tab,
          onChanged: onChanged,
          // One segment left, so there is nothing to switch to. Drawn the
          // same way the preview pane draws its own header label rather
          // than as plain text, so the two pane headers still match.
          interactive: kOpenCodeAgentEnabled,
          onMutedSurface: true,
          segments: const [
            if (kOpenCodeAgentEnabled)
              TextSegment(value: TerminalPaneTab.agent, label: 'Agent'),
            TextSegment(
              value: TerminalPaneTab.serverLogs,
              label: 'Server logs',
            ),
          ],
        ),
      ),
    );
  }
}
