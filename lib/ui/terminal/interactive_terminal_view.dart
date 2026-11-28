import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shad/shad.dart';
import 'package:xterm/xterm.dart';

import '../../theme/app_theme.dart';

/// Font size for terminal output.
const kTerminalFontSize = 12.0;

/// The terminal's content inset on every side.
const kTerminalPadding = 8.0;

/// A terminal the user types into — for a CLI that asks questions, like
/// `serverpod cloud launch`.
///
/// The server log used to be an xterm too, deliberately output-only. This one
/// is the opposite, and the hard part is the same: **which keys it keeps.**
/// Everything a CLI can read goes to it — letters, Enter, Escape, Tab, the
/// arrows, Ctrl chords (Ctrl-C included, as at any terminal). What it must not
/// keep is the app's own shortcuts: a key Flutter reports as handled never
/// reaches the menu bar, and the old log once took ⌘W and typed it as a `w`.
///
/// - **⌘ chords go to the menu bar on macOS**, except copy, paste and select
///   all, which act on the terminal. `onKeyEvent` answers
///   [KeyEventResult.skipRemainingHandlers] for them before xterm can turn the
///   letter into input. A CLI never sees ⌘ anyway — no terminal sends it.
/// - **On Windows, Ctrl belongs to the terminal**, as it does in Windows
///   Terminal, so copy is Ctrl+Shift+C and paste is Ctrl+V or Ctrl+Shift+V.
///   Ctrl+A stays the CLI's (start of line), so there is no select all.
/// - **`hardwareKeyboardOnly` stays off.** On, xterm uses a listener that
///   types any key it did not otherwise handle into the terminal and reports
///   it handled — the trap the old log fell into. Off, text arrives through
///   the text-input path, which also gives the IME what it needs.
class InteractiveTerminalView extends StatelessWidget {
  const InteractiveTerminalView({
    super.key,
    required this.terminal,
    this.readOnly = false,
    this.autofocus = true,
    this.focusNode,
  });

  final Terminal terminal;

  /// True once the program has exited: there is nothing left to type to.
  final bool readOnly;
  final bool autofocus;
  final FocusNode? focusNode;

  /// The palette.
  ///
  /// Chrome — cursor, selection, foreground, background — comes from the shad
  /// theme. The sixteen ANSI slots do not: they are the palette a program's
  /// escape codes address by index, so they are fixed values here rather than
  /// theme tokens that would shift under the program's feet.
  static TerminalTheme terminalTheme(ShadThemeData theme) {
    final scheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final common = (
      cursor: scheme.foreground,
      selection: scheme.selection.withValues(alpha: 0.35),
      foreground: scheme.foreground,
      background: scheme.background,
      brightBlack: scheme.mutedForeground,
      searchHitBackground: const Color(0x66FBBF24),
      searchHitBackgroundCurrent: const Color(0x99F59E0B),
    );
    if (isDark) {
      return TerminalTheme(
        cursor: common.cursor,
        selection: common.selection,
        foreground: common.foreground,
        background: common.background,
        black: const Color(0xFF1E293B),
        red: const Color(0xFFEF4444),
        green: const Color(0xFF22C55E),
        yellow: const Color(0xFFF59E0B),
        blue: kBrandBlue,
        magenta: const Color(0xFFA855F7),
        cyan: const Color(0xFF14B8A6),
        white: scheme.foreground,
        brightBlack: common.brightBlack,
        brightRed: const Color(0xFFFCA5A5),
        brightGreen: const Color(0xFF86EFAC),
        brightYellow: const Color(0xFFFBBF24),
        brightBlue: const Color(0xFF93C5FD),
        brightMagenta: const Color(0xFFC4B5FD),
        brightCyan: const Color(0xFF5EEAD4),
        brightWhite: scheme.foreground,
        searchHitBackground: common.searchHitBackground,
        searchHitBackgroundCurrent: common.searchHitBackgroundCurrent,
        searchHitForeground: scheme.foreground,
      );
    }
    return TerminalTheme(
      cursor: common.cursor,
      selection: common.selection,
      foreground: common.foreground,
      background: common.background,
      black: const Color(0xFF0F172A),
      red: const Color(0xFFDC2626),
      green: const Color(0xFF16A34A),
      yellow: const Color(0xFFB45309),
      blue: kBrandBlue,
      magenta: const Color(0xFF9333EA),
      cyan: const Color(0xFF0F766E),
      white: const Color(0xFF334155),
      brightBlack: common.brightBlack,
      brightRed: const Color(0xFFEF4444),
      brightGreen: const Color(0xFF10B981),
      brightYellow: const Color(0xFFD97706),
      brightBlue: const Color(0xFF3B82F6),
      brightMagenta: const Color(0xFFA855F7),
      brightCyan: const Color(0xFF14B8A6),
      brightWhite: scheme.foreground,
      searchHitBackground: common.searchHitBackground,
      searchHitBackgroundCurrent: common.searchHitBackgroundCurrent,
      searchHitForeground: scheme.foreground,
    );
  }

  static final _macShortcuts = <ShortcutActivator, Intent>{
    const SingleActivator(LogicalKeyboardKey.keyC, meta: true):
        CopySelectionTextIntent.copy,
    const SingleActivator(LogicalKeyboardKey.keyV, meta: true):
        const PasteTextIntent(SelectionChangedCause.keyboard),
    const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
        const SelectAllTextIntent(SelectionChangedCause.keyboard),
  };

  static final _windowsShortcuts = <ShortcutActivator, Intent>{
    const SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true):
        CopySelectionTextIntent.copy,
    const SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true):
        const PasteTextIntent(SelectionChangedCause.keyboard),
    const SingleActivator(LogicalKeyboardKey.keyV, control: true):
        const PasteTextIntent(SelectionChangedCause.keyboard),
  };

  static final _macTerminalChords = {
    LogicalKeyboardKey.keyC,
    LogicalKeyboardKey.keyV,
    LogicalKeyboardKey.keyA,
  };

  /// Keyboard behaviour follows [defaultTargetPlatform], as `shortcutHint`
  /// does — the host in the app, and whatever a test sets in a test, so the
  /// Windows mapping can be tested on a Mac and the other way round.
  static bool get _ctrlIsTerminal =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  /// Lets ⌘ chords past xterm to the menu bar. See the class comment.
  static KeyEventResult _routeKey(FocusNode node, KeyEvent event) {
    if (_ctrlIsTerminal) return KeyEventResult.ignored;
    if (!HardwareKeyboard.instance.isMetaPressed) return KeyEventResult.ignored;
    if (_macTerminalChords.contains(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.skipRemainingHandlers;
  }

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    return TerminalView(
      terminal,
      theme: terminalTheme(theme),
      textStyle: TerminalStyle(
        fontSize: kTerminalFontSize,
        fontFamily: kMonoFont,
      ),
      padding: const EdgeInsets.all(kTerminalPadding),
      autofocus: autofocus,
      focusNode: focusNode,
      readOnly: readOnly,
      shortcuts: _ctrlIsTerminal ? _windowsShortcuts : _macShortcuts,
      onKeyEvent: _routeKey,
    );
  }
}
