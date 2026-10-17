import 'dart:async';
import 'dart:ui' show AppExitType;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:shad/shad.dart';

import '../agent/agent_controller.dart';
import '../process/serverpod_process.dart';
import '../session/project_session.dart';
import '../theme/theme_controller.dart';
import '../ui/server_log/log_view_controller.dart';
import '../ui/server_log/server_log_view.dart';

/// The Windows counterpart of [MacAppMenu]: the same commands with the same
/// rules for when each is live, as a menu strip across the top of the window
/// with `Ctrl` shortcuts — Windows has no menu bar of its own to add them to.
///
/// File · View · Server · Logs · Help, the Windows order: Settings and Exit
/// live in File, updates and Uninstall in Help. Every enabled/checked rule
/// here is the one `macos_app_menu.dart` applies to the same command; the two
/// are kept apart so macOS's native menu is untouched.
///
/// The shortcuts are a [HardwareKeyboard] handler rather than a `Shortcuts`
/// widget: they must work whatever has focus — the start page, the shell,
/// the preview — as the macOS menu's key equivalents do. None of them is a
/// key a text field uses.
class WindowsAppMenuBar extends StatefulWidget {
  const WindowsAppMenuBar({
    super.key,
    required this.session,
    required this.process,
    required this.agent,
    required this.themeController,
    required this.logView,
    required this.onNewProject,
    required this.onCheckForUpdates,
    required this.onUninstall,
    required this.canCheckForUpdates,
    required this.updatesUnavailableReason,
    required this.onSetAutomaticUpdates,
    required this.automaticUpdatesEnabled,
    required this.canOpenProjects,
    required this.onCreateAndApplyMigrations,
    required this.onCreateRepairMigration,
    required this.changes,
    required this.child,
    this.stripHidden,
  });

  final ProjectSession session;
  final ServerpodProcessController process;
  final AgentController agent;
  final ThemeController themeController;
  final LogViewController logView;
  final VoidCallback onNewProject;
  final VoidCallback onCheckForUpdates;
  final VoidCallback onUninstall;
  final bool Function() canCheckForUpdates;
  final String? Function() updatesUnavailableReason;
  final ValueChanged<bool> onSetAutomaticUpdates;
  final bool Function() automaticUpdatesEnabled;

  /// False while first-run setup owns the screen: no New, Open or Settings.
  final bool Function() canOpenProjects;
  final VoidCallback onCreateAndApplyMigrations;
  final VoidCallback onCreateRepairMigration;

  /// Anything else the menu reads that can change — the updater and the
  /// toolchain — so it is redrawn when they do.
  final Listenable changes;

  /// The app, under the menu strip.
  final Widget child;

  /// True while the strip should not show — the compact preview. The
  /// shortcuts stay live, as the macOS menu bar's do.
  final bool Function()? stripHidden;

  @override
  State<WindowsAppMenuBar> createState() => _WindowsAppMenuBarState();
}

class _WindowsAppMenuBarState extends State<WindowsAppMenuBar> {
  late Listenable _listenable;

  /// The runner's apps, by id and name: the Logs menu lists them. The log
  /// notifies on every line, so the menu redraws only when this changes.
  String _appsSignature = '';

  @override
  void initState() {
    super.initState();
    _listen();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void didUpdateWidget(WindowsAppMenuBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _unlisten(oldWidget);
    _listen();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _unlisten(widget);
    super.dispose();
  }

  void _listen() {
    _listenable = Listenable.merge([
      widget.session,
      widget.process,
      widget.logView,
      widget.themeController,
      widget.changes,
    ])
      ..addListener(_redraw);
    _appsSignature = _signature();
    widget.process.log.addListener(_onLogChanged);
  }

  void _unlisten(WindowsAppMenuBar of) {
    _listenable.removeListener(_redraw);
    of.process.log.removeListener(_onLogChanged);
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  String _signature() => [
        for (final app in widget.process.log.apps) '${app.id}\u0000${app.name}',
      ].join('\u0001');

  void _onLogChanged() {
    final signature = _signature();
    if (signature == _appsSignature) return;
    _appsSignature = signature;
    _redraw();
  }

  // -- commands -------------------------------------------------------------
  //
  // Each one re-checks its own rule: a shortcut can land between a state
  // change and the menu catching up with it.

  bool get _canOpen => widget.canOpenProjects();
  bool get _hasProject => widget.session.hasProject;
  bool get _idle => widget.process.runningAction == null;
  bool get _canHotRestart => widget.process.canHotRestart && _idle;
  bool get _canFullRestart => widget.process.canRestart;
  bool get _canMigrate => widget.process.canMigrate && _idle;

  Future<void> _newProject() async {
    if (!_canOpen) return;
    if (_hasProject) {
      await _closeProject();
      // `main.dart` clears pushed routes a frame after a project closes; a
      // screen pushed now would go with them.
      await WidgetsBinding.instance.endOfFrame;
    }
    widget.onNewProject();
  }

  void _open() {
    if (_canOpen) unawaited(widget.session.openProjectPicker());
  }

  Future<void> _closeProject() async {
    if (!_hasProject) return;
    if (widget.process.canStop) await widget.process.stop();
    widget.session.closeProject();
  }

  void _settings() {
    if (_canOpen) widget.agent.openSettings();
  }

  /// The same teardown the window's close button runs.
  void _exit() => unawaited(
        ServicesBinding.instance.exitApplication(AppExitType.cancelable),
      );

  void _hotRestart() {
    if (_canHotRestart) unawaited(widget.process.hotRestart());
  }

  void _fullRestart() {
    if (_canFullRestart) unawaited(widget.process.restart());
  }

  void _migrate() {
    if (_canMigrate) widget.onCreateAndApplyMigrations();
  }

  void _toggleLogs() {
    if (_hasProject) widget.logView.toggleVisible();
  }

  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final keyboard = HardwareKeyboard.instance;
    if (!keyboard.isControlPressed ||
        keyboard.isAltPressed ||
        keyboard.isMetaPressed) {
      return false;
    }
    final shift = keyboard.isShiftPressed;
    final VoidCallback? action = switch (event.logicalKey) {
      LogicalKeyboardKey.keyN when !shift => () => unawaited(_newProject()),
      LogicalKeyboardKey.keyO when !shift => _open,
      LogicalKeyboardKey.keyW when !shift => () => unawaited(_closeProject()),
      LogicalKeyboardKey.comma when !shift => _settings,
      LogicalKeyboardKey.keyR => shift ? _fullRestart : _hotRestart,
      LogicalKeyboardKey.keyM when !shift => _migrate,
      LogicalKeyboardKey.keyL when !shift => _toggleLogs,
      _ => null,
    };
    if (action == null) return false;
    action();
    return true;
  }

  // -- the strip ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = ShadTheme.of(context);
    final scheme = theme.colorScheme;
    // The menus open in an overlay; the navigator's own is below this.
    return Overlay.wrap(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Swapped for an empty box rather than removed, so [child] keeps
          // its place in the tree and nothing under it is rebuilt.
          if (widget.stripHidden?.call() ?? false)
            const SizedBox.shrink()
          else
            DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.background,
                border: Border(bottom: BorderSide(color: scheme.border)),
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: ShadMenubar(
                  border: ShadBorder.none,
                  radius: BorderRadius.zero,
                  backgroundColor: scheme.background,
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  items: [
                    _menu('File', _fileItems()),
                    _menu('View', _viewItems()),
                    _menu('Server', _serverItems()),
                    _menu('Logs', _logsItems()),
                    _menu('Help', _helpItems()),
                  ],
                ),
              ),
            ),
          Expanded(child: widget.child),
        ],
      ),
    );
  }

  Widget _menu(String title, List<Widget> items) =>
      ShadMenubarItem(items: items, child: Text(title));

  static const _divider = ShadSeparator.horizontal(
    margin: EdgeInsets.symmetric(vertical: 4),
  );

  Widget _item(
    String label, {
    VoidCallback? onPressed,
    bool enabled = true,
    String? shortcut,
    bool? checked,
    List<Widget> items = const [],
  }) {
    final trailing = items.isNotEmpty
        ? const Icon(LucideIcons.chevronRight, size: 16)
        : shortcut == null
            ? null
            : Text(shortcut);
    final child = Text(label);
    if (checked == null) {
      return ShadContextMenuItem(
        enabled: enabled,
        onPressed: onPressed,
        trailing: trailing,
        items: items,
        child: child,
      );
    }
    return checked
        ? ShadContextMenuItem(
            enabled: enabled,
            onPressed: onPressed,
            leading: const Icon(LucideIcons.check, size: 16),
            trailing: trailing,
            child: child,
          )
        : ShadContextMenuItem.inset(
            enabled: enabled,
            onPressed: onPressed,
            trailing: trailing,
            child: child,
          );
  }

  List<Widget> _fileItems() {
    final recents = widget.session.recents;
    return [
      _item(
        'New Project',
        shortcut: 'Ctrl+N',
        enabled: _canOpen,
        onPressed: () => unawaited(_newProject()),
      ),
      _item('Open...', shortcut: 'Ctrl+O', enabled: _canOpen, onPressed: _open),
      _item(
        'Open Recent',
        enabled: recents.isNotEmpty && _canOpen,
        items: [
          for (final path in recents)
            _item(
              p.basename(path),
              onPressed: () => unawaited(widget.session.openPath(path)),
            ),
        ],
      ),
      _divider,
      _item(
        'Close',
        shortcut: 'Ctrl+W',
        enabled: _hasProject,
        onPressed: () => unawaited(_closeProject()),
      ),
      _divider,
      _item(
        'Settings...',
        shortcut: 'Ctrl+,',
        enabled: _canOpen,
        onPressed: _settings,
      ),
      _divider,
      _item('Exit', shortcut: 'Alt+F4', onPressed: _exit),
    ];
  }

  List<Widget> _viewItems() {
    final mode = widget.themeController.mode;
    void set(ThemeMode m) => unawaited(widget.themeController.setMode(m));
    return [
      _item(
        'Appearance',
        items: [
          _item(
            'Use System Appearance',
            checked: mode == ThemeMode.system,
            onPressed: () => set(ThemeMode.system),
          ),
          _divider,
          _item(
            'Light Mode',
            checked: mode == ThemeMode.light,
            onPressed: () => set(ThemeMode.light),
          ),
          _item(
            'Dark Mode',
            checked: mode == ThemeMode.dark,
            onPressed: () => set(ThemeMode.dark),
          ),
        ],
      ),
    ];
  }

  List<Widget> _serverItems() => [
        _item(
          'Hot Restart',
          shortcut: 'Ctrl+R',
          enabled: _canHotRestart,
          onPressed: _hotRestart,
        ),
        _item(
          'Full Restart',
          shortcut: 'Ctrl+Shift+R',
          enabled: _canFullRestart,
          onPressed: _fullRestart,
        ),
        _divider,
        _item(
          'Create and Apply Migrations',
          shortcut: 'Ctrl+M',
          enabled: _canMigrate,
          onPressed: _migrate,
        ),
        _item(
          'Create Repair Migration',
          enabled: _canMigrate,
          onPressed: widget.onCreateRepairMigration,
        ),
      ];

  List<Widget> _logsItems() {
    final logView = widget.logView;
    final open = _hasProject;
    final tab = logView.tab;
    return [
      _item(
        logView.visible ? 'Hide Logs' : 'Show Logs',
        shortcut: 'Ctrl+L',
        enabled: open,
        onPressed: _toggleLogs,
      ),
      _divider,
      _item(
        'Server',
        enabled: open,
        checked: tab == LeftPaneTab.server,
        onPressed: () => logView.show(const ServerLogSource()),
      ),
      for (final app in widget.process.log.apps)
        _item(
          app.name,
          enabled: open,
          checked: tab == LogTab(AppLogSource(app.id)),
          onPressed: () => logView.show(AppLogSource(app.id)),
        ),
      _divider,
      _item(
        'Log Level',
        enabled: open,
        items: [
          for (final level in LogLevelFilter.values)
            _item(
              level.label,
              checked: logView.level == level,
              onPressed: () => logView.level = level,
            ),
        ],
      ),
    ];
  }

  List<Widget> _helpItems() {
    final canCheck = widget.canCheckForUpdates();
    final reason = widget.updatesUnavailableReason();
    return [
      _item(
        reason == null ? 'Check for Updates...' : 'Check for Updates ($reason)',
        enabled: canCheck,
        onPressed: widget.onCheckForUpdates,
      ),
      _item(
        'Check for Updates Automatically',
        enabled: canCheck,
        checked: widget.automaticUpdatesEnabled(),
        onPressed: () =>
            widget.onSetAutomaticUpdates(!widget.automaticUpdatesEnabled()),
      ),
      _divider,
      _item('Uninstall App Studio...', onPressed: widget.onUninstall),
    ];
  }
}
