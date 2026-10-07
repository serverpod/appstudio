import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mac_menu_bar/mac_menu_bar.dart';
import 'package:path/path.dart' as p;

import '../agent/agent_controller.dart';
import '../process/serverpod_process.dart';
import '../session/project_session.dart';
import '../theme/theme_controller.dart';
import '../ui/server_log/log_view_controller.dart';
import '../ui/server_log/server_log_view.dart';

/// Adds custom menus to the native macOS menu bar while preserving the
/// standard items from MainMenu.xib.
class MacAppMenu {
  MacAppMenu({
    required this.session,
    required this.process,
    required this.agent,
    required this.themeController,
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
    required this.logView,
  }) {
    session.addListener(_sync);
    themeController.addListener(_sync);
    process.addListener(_syncServerMenu);
    logView.addListener(_syncLogsMenu);
    process.log.addListener(_onLogChanged);
  }

  static const _checkUpdatesId = 'app_check_updates';
  static const _checkUpdatesIcon = 'arrow.down.circle';
  static const _autoUpdatesId = 'app_auto_updates';
  static const _uninstallId = 'app_uninstall';
  static const _uninstallSepId = 'app_uninstall_sep';
  static const _uninstallIcon = 'trash';
  static const _checkUpdatesTitle = 'Check for Updates...';
  static const _viewMenuId = 'View';
  static const _fileMenuId = 'file';
  static const _openRecentId = 'file_open_recent';
  static const _separatorId = 'file_sep';
  static const _appearanceSubmenuId = 'view_appearance';
  static const _appearanceSepId = 'view_appearance_sep';
  static const _viewAppearanceMenuSepId = 'view_appearance_menu_sep';
  static const _newProjectIcon = 'plus';
  static const _openIcon = 'arrow.up.right';
  static const _openRecentIcon = 'clock';
  static const _closeIcon = 'xmark';
  static const _appearanceIcon = 'circle.lefthalf.filled';
  static const _systemAppearanceIcon = 'desktopcomputer';
  static const _lightModeIcon = 'sun.max';
  static const _darkModeIcon = 'moon';
  static const _newProjectId = 'file_new_project';
  static const _openId = 'file_open';
  static const _closeId = 'file_close';
  static const _appearanceSystemId = 'view_appearance_system';
  static const _appearanceLightId = 'view_appearance_light';
  static const _appearanceDarkId = 'view_appearance_dark';
  static const _serverMenuId = 'server';
  static const _hotRestartId = 'server_hot_restart';
  static const _fullRestartId = 'server_full_restart';
  static const _serverSepId = 'server_sep';
  static const _migrateId = 'server_migrate';
  static const _repairMigrationId = 'server_repair_migration';
  static const _logsMenuId = 'logs';
  static const _logsToggleId = 'logs_toggle';
  static const _logsSourcesSepId = 'logs_sources_sep';
  static const _logsServerId = 'logs_source_server';
  static const _logsLevelSepId = 'logs_level_sep';
  static const _logsLevelMenuId = 'logs_level';
  static const _logsAppPrefix = 'logs_source_app_';
  static const _logsLevelPrefix = 'logs_level_';

  final ProjectSession session;
  final ServerpodProcessController process;
  final AgentController agent;
  final ThemeController themeController;
  final VoidCallback onNewProject;
  final VoidCallback onCheckForUpdates;
  final VoidCallback onUninstall;
  final ValueChanged<bool> onSetAutomaticUpdates;

  /// Current value of the "check automatically" preference, read at sync time
  /// rather than captured — it changes whenever Sparkle's own UI changes it.
  final bool Function() automaticUpdatesEnabled;

  /// False in debug builds and when the app is running translocated, in which
  /// case the item is installed but greyed out — a missing menu item is a
  /// worse question than a disabled one.
  final bool Function() canCheckForUpdates;

  /// Why checking is unavailable, or null when it is available. Shown in the
  /// item's own title: a greyed-out entry that does not say why reads as a
  /// bug, and the commonest cause (running from ~/Downloads) has a fix the
  /// user can act on.
  final String? Function() updatesUnavailableReason;

  /// False while first-run setup still owns the screen.
  ///
  /// Gates File → Open / Open Recent and the App Studio → Settings item.
  /// Opening a project then would auto-start a server with no Flutter SDK to
  /// build it, and Settings configures an agent whose binary is one of the
  /// things still being downloaded. The setup screen deliberately offers no way
  /// to either, so the menu has to agree.
  final bool Function() canOpenProjects;

  /// The Server menu's migration commands. They raise a dialog and toasts, so
  /// `main.dart` runs them with the navigator's context.
  final VoidCallback onCreateAndApplyMigrations;
  final VoidCallback onCreateRepairMigration;

  /// The log panel's visibility, selected log and level — what the Logs menu
  /// sets, and what its checkmarks follow.
  final LogViewController logView;

  /// The Flutter apps the Logs menu lists, by item id, in the runner's order.
  /// Rebuilt only when the runner's app list changes: the log notifies on
  /// every line, and removing and re-adding items that often would be absurd.
  List<(String id, String appId)> _logApps = [];
  String _logAppsSignature = '';

  /// Rebuilds run one after another: two overlapping ones would remove the
  /// same items twice and add theirs twice.
  Future<void> _logAppsQueue = Future.value();

  bool _installed = false;
  List<String> _recentItemIds = [];

  Future<void> install() async {
    if (!Platform.isMacOS || _installed) return;

    // A hot restart replaces the Dart isolate but not the engine, its plugins
    // or the native menu bar, so everything below would be added a second time
    // — and `_recentItemIds` comes back empty, so Open Recent duplicates too.
    // Clearing first makes install idempotent.
    await MacMenuBar.reset();

    MacMenuBar.setMenuItemSelectedHandler(_onItemSelected);

    // Before the menus, not after: the plugin installs its Settings override
    // from a block queued at registration, which force-enables the item, and
    // its own flag defaults to enabled — so until this lands the stock item is
    // live and ⌘, reaches the action without the menu ever being drawn. The
    // native side re-applies whatever it was last told, so an override that
    // installs after this call still ends up here.
    await MacMenuBar.setSettingsEnabled(canOpenProjects());

    MacMenuBar.onCut(() async => false);
    MacMenuBar.onCopy(() async => false);
    MacMenuBar.onPaste(() async => false);
    MacMenuBar.onSelectAll(() async => false);
    MacMenuBar.onSettings(() async {
      agent.openSettings();
      return true;
    });

    await _installFileMenu();
    await _installViewMenu();
    await _installServerMenu();
    await _installLogsMenu();
    await _installAppMenuItems();

    _installed = true;
    await _syncRecents();
    await _syncAppearance();
    await _syncServerMenu();
    await (_logAppsQueue = _logAppsQueue.then((_) => _syncLogApps()));
    await _syncLogsMenu();
  }

  String get _checkUpdatesLabel {
    final reason = updatesUnavailableReason();
    return reason == null ? _checkUpdatesTitle : 'Check for Updates ($reason)';
  }

  /// Puts the update items next to About, and Uninstall directly below
  /// Settings.
  ///
  /// `mac_menu_bar` addresses menus by their NSMenu *title*. For the
  /// application menu that title is `APP_NAME` — the literal placeholder from
  /// `MainMenu.xib`, which nothing ever substitutes; macOS renders the menu
  /// using the bundle name instead, so users still read "App Studio". Verified
  /// by running the release build and reading the log line below. The product
  /// name is tried too, in case a future Flutter template starts substituting
  /// it.
  ///
  /// The File menu is the last resort. It is a strange home for these, but a
  /// build with no way to check for updates — or worse, no way to uninstall —
  /// is worse than one where the items sit somewhere unexpected.
  Future<void> _installAppMenuItems() async {
    const candidates = ['APP_NAME', 'App Studio', 'AppStudio'];

    for (final menuId in candidates) {
      final added = await MacMenuBar.addMenuItem(
        menuId: menuId,
        itemId: _checkUpdatesId,
        // Directly under "About App Studio", above the first separator.
        index: 1,
        title: _checkUpdatesLabel,
        systemImage: _checkUpdatesIcon,
        enabled: canCheckForUpdates(),
      );
      if (!added) continue;

      debugPrint('MacAppMenu: app menu items installed in "$menuId" menu');
      await _addAutomaticUpdatesItem(menuId, index: 2);
      // The stock menu is About(0), separator, Settings…; the two items above
      // shift Settings… to index 4, so 5 puts Uninstall immediately below it.
      // The separator that already follows Settings… ends up under Uninstall,
      // which keeps it out of the Services group.
      await _addUninstallItem(menuId, index: 5);
      return;
    }

    debugPrint(
      'MacAppMenu: could not reach the application menu; '
      'update and uninstall items went to the File menu instead',
    );
    await MacMenuBar.addMenuSeparator(
      menuId: _fileMenuId,
      itemId: _uninstallSepId,
      index: 90,
    );
    await MacMenuBar.addMenuItem(
      menuId: _fileMenuId,
      itemId: _checkUpdatesId,
      title: _checkUpdatesLabel,
      index: 91,
      systemImage: _checkUpdatesIcon,
      enabled: canCheckForUpdates(),
    );
    await _addAutomaticUpdatesItem(_fileMenuId, index: 92);
    await _addUninstallItem(_fileMenuId, index: 93);
  }

  /// "Uninstall..." — removes every supporting file, not the app bundle.
  ///
  /// Sits with Settings because that is what it clears: preferences, the shell
  /// PATH entry and the downloaded tools. No separator of its own — the stock
  /// one that follows Settings… lands underneath it.
  Future<void> _addUninstallItem(String menuId, {required int index}) async {
    await MacMenuBar.addMenuItem(
      menuId: menuId,
      itemId: _uninstallId,
      title: 'Uninstall...',
      index: index,
      systemImage: _uninstallIcon,
    );
  }

  /// The "check automatically" preference, as a checked menu item.
  ///
  /// A checked item next to the action it governs, which is the macOS-native
  /// place for it, and keeps Sparkle as the single owner of the preference.
  Future<void> _addAutomaticUpdatesItem(String menuId, {required int index}) async {
    await MacMenuBar.addMenuItem(
      menuId: menuId,
      itemId: _autoUpdatesId,
      title: 'Check for Updates Automatically',
      index: index,
      enabled: canCheckForUpdates(),
    );
    await MacMenuBar.setMenuItemChecked(
      _autoUpdatesId,
      automaticUpdatesEnabled(),
    );
  }

  Future<void> _installFileMenu() async {
    await MacMenuBar.addSubmenu(
      parentMenuId: 'main',
      submenuId: _fileMenuId,
      title: 'File',
      index: 1,
    );

    await MacMenuBar.addMenuItem(
      menuId: _fileMenuId,
      itemId: _newProjectId,
      title: 'New Project',
      index: 0,
      systemImage: _newProjectIcon,
      shortcut: const SingleActivator(
        LogicalKeyboardKey.keyN,
        meta: true,
      ),
      enabled: false,
    );

    await MacMenuBar.addMenuItem(
      menuId: _fileMenuId,
      itemId: _openId,
      title: 'Open...',
      index: 1,
      systemImage: _openIcon,
      shortcut: const SingleActivator(
        LogicalKeyboardKey.keyO,
        meta: true,
      ),
      // Correct from the first frame: install() runs before the first _sync,
      // and on a fresh Mac that frame is the toolchain setup screen.
      enabled: canOpenProjects(),
    );

    await MacMenuBar.addSubmenu(
      parentMenuId: _fileMenuId,
      submenuId: _openRecentId,
      title: 'Open Recent',
      index: 2,
      systemImage: _openRecentIcon,
    );

    await MacMenuBar.addMenuSeparator(
      menuId: _fileMenuId,
      itemId: _separatorId,
      index: 3,
    );

    await MacMenuBar.addMenuItem(
      menuId: _fileMenuId,
      itemId: _closeId,
      title: 'Close',
      index: 4,
      systemImage: _closeIcon,
      shortcut: const SingleActivator(
        LogicalKeyboardKey.keyW,
        meta: true,
      ),
      enabled: session.hasProject,
    );
  }

  Future<void> _installViewMenu() async {
    await MacMenuBar.addSubmenu(
      parentMenuId: _viewMenuId,
      submenuId: _appearanceSubmenuId,
      title: 'Appearance',
      index: 0,
      systemImage: _appearanceIcon,
    );

    await MacMenuBar.addMenuSeparator(
      menuId: _viewMenuId,
      itemId: _viewAppearanceMenuSepId,
      index: 1,
    );

    await MacMenuBar.addMenuItem(
      menuId: _appearanceSubmenuId,
      itemId: _appearanceSystemId,
      title: 'Use System Appearance',
      index: 0,
      systemImage: _systemAppearanceIcon,
    );

    await MacMenuBar.addMenuSeparator(
      menuId: _appearanceSubmenuId,
      itemId: _appearanceSepId,
      index: 1,
    );

    await MacMenuBar.addMenuItem(
      menuId: _appearanceSubmenuId,
      itemId: _appearanceLightId,
      title: 'Light Mode',
      index: 2,
      systemImage: _lightModeIcon,
    );

    await MacMenuBar.addMenuItem(
      menuId: _appearanceSubmenuId,
      itemId: _appearanceDarkId,
      title: 'Dark Mode',
      index: 3,
      systemImage: _darkModeIcon,
    );
  }

  /// The running project's commands: the two restarts and the database
  /// migrations, all of which act on the Serverpod runner. Between View and
  /// Window, where an app's own verbs go.
  ///
  /// ⌘M is taken from Window → Minimize, whose shortcut MainMenu.xib no longer
  /// sets: two items on one key equivalent leave AppKit to pick whichever it
  /// meets first, and Minimize is a click away in the window's title bar.
  Future<void> _installServerMenu() async {
    await MacMenuBar.addSubmenu(
      parentMenuId: 'main',
      submenuId: _serverMenuId,
      title: 'Server',
      index: 4,
    );

    await MacMenuBar.addMenuItem(
      menuId: _serverMenuId,
      itemId: _hotRestartId,
      title: 'Hot Restart',
      index: 0,
      systemImage: 'bolt',
      shortcut: const SingleActivator(LogicalKeyboardKey.keyR, meta: true),
      enabled: false,
    );

    await MacMenuBar.addMenuItem(
      menuId: _serverMenuId,
      itemId: _fullRestartId,
      title: 'Full Restart',
      index: 1,
      systemImage: 'arrow.counterclockwise',
      shortcut: const SingleActivator(
        LogicalKeyboardKey.keyR,
        meta: true,
        shift: true,
      ),
      enabled: false,
    );

    await MacMenuBar.addMenuSeparator(
      menuId: _serverMenuId,
      itemId: _serverSepId,
      index: 2,
    );

    await MacMenuBar.addMenuItem(
      menuId: _serverMenuId,
      itemId: _migrateId,
      title: 'Create and Apply Migrations',
      index: 3,
      systemImage: 'cylinder.split.1x2',
      shortcut: const SingleActivator(LogicalKeyboardKey.keyM, meta: true),
      enabled: false,
    );

    await MacMenuBar.addMenuItem(
      menuId: _serverMenuId,
      itemId: _repairMigrationId,
      title: 'Create Repair Migration',
      index: 4,
      systemImage: 'wrench.and.screwdriver',
      enabled: false,
    );
  }

  /// Follows the runner: each command is live exactly when the matching
  /// toolbar button is, and nothing is offered while another runner action is
  /// in flight. Its own listener rather than [_sync], which rebuilds Open
  /// Recent — too much to redo on every server state change.
  Future<void> _syncServerMenu() async {
    if (!_installed) return;
    final idle = process.runningAction == null;
    await MacMenuBar.setMenuItemEnabled(
      _hotRestartId,
      process.canHotRestart && idle,
    );
    await MacMenuBar.setMenuItemEnabled(_fullRestartId, process.canRestart);
    await MacMenuBar.setMenuItemEnabled(_migrateId, process.canMigrate && idle);
    await MacMenuBar.setMenuItemEnabled(
      _repairMigrationId,
      process.canMigrate && idle,
    );
  }

  /// The log panel and what it shows: Show/Hide Logs, one checked item per log
  /// — the server's, then each Flutter app's — and the lowest level shown.
  /// Right of Server, before Window.
  Future<void> _installLogsMenu() async {
    await MacMenuBar.addSubmenu(
      parentMenuId: 'main',
      submenuId: _logsMenuId,
      title: 'Logs',
      index: 5,
    );

    await MacMenuBar.addMenuItem(
      menuId: _logsMenuId,
      itemId: _logsToggleId,
      title: 'Hide Logs',
      index: 0,
      systemImage: 'sidebar.left',
      enabled: false,
    );

    await MacMenuBar.addMenuSeparator(
      menuId: _logsMenuId,
      itemId: _logsSourcesSepId,
      index: 1,
    );

    await MacMenuBar.addMenuItem(
      menuId: _logsMenuId,
      itemId: _logsServerId,
      title: 'Server',
      index: 2,
      enabled: false,
    );

    // The apps go between the server and this separator (`_syncLogApps`).
    await MacMenuBar.addMenuSeparator(
      menuId: _logsMenuId,
      itemId: _logsLevelSepId,
      index: 3,
    );

    await MacMenuBar.addSubmenu(
      parentMenuId: _logsMenuId,
      submenuId: _logsLevelMenuId,
      title: 'Log Level',
      index: 4,
      systemImage: 'line.3.horizontal.decrease',
    );

    for (final (index, level) in LogLevelFilter.values.indexed) {
      await MacMenuBar.addMenuItem(
        menuId: _logsLevelMenuId,
        itemId: '$_logsLevelPrefix${level.name}',
        title: level.label,
        index: index,
      );
    }
  }

  String _appsSignature() => [
        for (final app in process.log.apps) '${app.id}\u0000${app.name}',
      ].join('\u0001');

  void _onLogChanged() {
    if (!_installed) return;
    final signature = _appsSignature();
    if (signature == _logAppsSignature) return;
    // Claimed now, so the lines that follow do not queue a rebuild each.
    _logAppsSignature = signature;
    _logAppsQueue = _logAppsQueue
        .then((_) => _syncLogApps())
        .then((_) => _syncLogsMenu());
  }

  /// Replaces the app items with the runner's current apps.
  Future<void> _syncLogApps() async {
    if (!_installed) return;
    final apps = process.log.apps;
    _logAppsSignature = _appsSignature();
    for (final (id, _) in _logApps) {
      await MacMenuBar.removeMenuItem(id);
    }
    _logApps = [];
    for (final (index, app) in apps.indexed) {
      final id = '$_logsAppPrefix$index';
      await MacMenuBar.addMenuItem(
        menuId: _logsMenuId,
        itemId: id,
        title: app.name,
        index: 3 + index,
      );
      _logApps.add((id, app.id));
    }
  }

  /// Checkmarks and enabled state follow the panel. Nothing is offered with no
  /// project open: there is no panel to show and no log to pick.
  Future<void> _syncLogsMenu() async {
    if (!_installed) return;
    final open = session.hasProject;
    await MacMenuBar.updateMenuItem(
      itemId: _logsToggleId,
      title: logView.visible ? 'Hide Logs' : 'Show Logs',
      enabled: open,
    );
    final tab = logView.tab;
    await MacMenuBar.setMenuItemEnabled(_logsServerId, open);
    await MacMenuBar.setMenuItemChecked(
      _logsServerId,
      tab == LeftPaneTab.server,
    );
    for (final (id, appId) in _logApps) {
      await MacMenuBar.setMenuItemEnabled(id, open);
      await MacMenuBar.setMenuItemChecked(
        id,
        tab == LogTab(AppLogSource(appId)),
      );
    }
    await MacMenuBar.setMenuItemEnabled(_logsLevelMenuId, open);
    for (final level in LogLevelFilter.values) {
      await MacMenuBar.setMenuItemChecked(
        '$_logsLevelPrefix${level.name}',
        logView.level == level,
      );
    }
  }

  void dispose() {
    session.removeListener(_sync);
    themeController.removeListener(_sync);
    process.removeListener(_syncServerMenu);
    logView.removeListener(_syncLogsMenu);
    process.log.removeListener(_onLogChanged);
  }

  void _onItemSelected(String itemId) {
    switch (itemId) {
      case _newProjectId:
        onNewProject();
      case _checkUpdatesId:
        onCheckForUpdates();
      case _uninstallId:
        onUninstall();
      case _autoUpdatesId:
        // Sparkle owns the value; toggle it and let the sync reflect whatever
        // it actually became.
        onSetAutomaticUpdates(!automaticUpdatesEnabled());
      case _openId:
        unawaited(session.openProjectPicker());
      case _closeId:
        unawaited(_closeProject());
      case _appearanceSystemId:
        unawaited(themeController.setMode(ThemeMode.system));
      case _appearanceLightId:
        unawaited(themeController.setMode(ThemeMode.light));
      case _appearanceDarkId:
        unawaited(themeController.setMode(ThemeMode.dark));
      // Re-checked here as well as by the enabled state: a shortcut can land
      // between a state change and the menu catching up with it.
      case _hotRestartId:
        if (process.canHotRestart) unawaited(process.hotRestart());
      case _fullRestartId:
        if (process.canRestart) unawaited(process.restart());
      case _migrateId:
        onCreateAndApplyMigrations();
      case _repairMigrationId:
        onCreateRepairMigration();
      case _logsToggleId:
        if (session.hasProject) logView.toggleVisible();
      case _logsServerId:
        logView.show(const ServerLogSource());
      default:
        if (itemId.startsWith(_logsLevelPrefix)) {
          final name = itemId.substring(_logsLevelPrefix.length);
          for (final level in LogLevelFilter.values) {
            if (level.name == name) logView.level = level;
          }
          return;
        }
        if (itemId.startsWith(_logsAppPrefix)) {
          for (final (id, appId) in _logApps) {
            if (id == itemId) logView.show(AppLogSource(appId));
          }
          return;
        }
        if (itemId.startsWith('file_recent_')) {
          final index = int.tryParse(itemId.substring('file_recent_'.length));
          if (index != null && index < session.recents.length) {
            unawaited(session.openPath(session.recents[index]));
          }
        }
    }
  }

  Future<void> _closeProject() async {
    if (!session.hasProject) return;
    if (process.canStop) {
      await process.stop();
    }
    session.closeProject();
  }

  /// Re-applies enabled/checked state. Public so `main.dart` can call it when
  /// the updater settles after launch.
  void refresh() => _sync();

  void _sync() {
    if (!_installed) return;
    final canOpen = canOpenProjects();
    unawaited(MacMenuBar.setMenuItemEnabled(_openId, canOpen));
    unawaited(MacMenuBar.setSettingsEnabled(canOpen));
    unawaited(MacMenuBar.setMenuItemEnabled(_closeId, session.hasProject));
    unawaited(
      MacMenuBar.updateMenuItem(
        itemId: _checkUpdatesId,
        title: _checkUpdatesLabel,
        enabled: canCheckForUpdates(),
      ),
    );
    unawaited(
      MacMenuBar.setMenuItemEnabled(_autoUpdatesId, canCheckForUpdates()),
    );
    unawaited(
      MacMenuBar.setMenuItemChecked(_autoUpdatesId, automaticUpdatesEnabled()),
    );
    unawaited(_syncRecents());
    unawaited(_syncAppearance());
    unawaited(_syncLogsMenu());
  }

  Future<void> _syncRecents() async {
    for (final id in _recentItemIds) {
      await MacMenuBar.removeMenuItem(id);
    }
    _recentItemIds = [];

    final recents = session.recents;
    await MacMenuBar.setMenuItemEnabled(
      _openRecentId,
      recents.isNotEmpty && canOpenProjects(),
    );

    for (var i = 0; i < recents.length; i++) {
      final id = 'file_recent_$i';
      await MacMenuBar.addMenuItem(
        menuId: _openRecentId,
        itemId: id,
        title: p.basename(recents[i]),
      );
      _recentItemIds.add(id);
    }
  }

  Future<void> _syncAppearance() async {
    final mode = themeController.mode;
    await MacMenuBar.setMenuItemChecked(
      _appearanceSystemId,
      mode == ThemeMode.system,
    );
    await MacMenuBar.setMenuItemChecked(
      _appearanceLightId,
      mode == ThemeMode.light,
    );
    await MacMenuBar.setMenuItemChecked(
      _appearanceDarkId,
      mode == ThemeMode.dark,
    );
  }
}
