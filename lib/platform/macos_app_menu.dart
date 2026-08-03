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

/// Adds custom menus to the native macOS menu bar while preserving the
/// standard items from MainMenu.xib.
class MacAppMenu {
  MacAppMenu({
    required this.session,
    required this.process,
    required this.agent,
    required this.themeController,
    required this.onNewProject,
    required this.onManageTools,
    required this.onCheckForUpdates,
    required this.canCheckForUpdates,
    required this.updatesUnavailableReason,
    required this.onSetAutomaticUpdates,
    required this.automaticUpdatesEnabled,
  }) {
    session.addListener(_sync);
    themeController.addListener(_sync);
  }

  static const _toolsMenuId = 'tools';
  static const _manageToolsId = 'tools_manage';
  static const _manageToolsIcon = 'wrench.and.screwdriver';
  static const _checkUpdatesId = 'app_check_updates';
  static const _checkUpdatesIcon = 'arrow.down.circle';
  static const _autoUpdatesId = 'app_auto_updates';
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

  final ProjectSession session;
  final ServerpodProcessController process;
  final AgentController agent;
  final ThemeController themeController;
  final VoidCallback onNewProject;
  final VoidCallback onManageTools;
  final VoidCallback onCheckForUpdates;
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

  bool _installed = false;
  List<String> _recentItemIds = [];

  Future<void> install() async {
    if (!Platform.isMacOS || _installed) return;

    MacMenuBar.setMenuItemSelectedHandler(_onItemSelected);

    MacMenuBar.onCut(() async => false);
    MacMenuBar.onCopy(() async => false);
    MacMenuBar.onPaste(() async => false);
    MacMenuBar.onSelectAll(() async => false);
    MacMenuBar.onSettings(() async {
      agent.openSettings();
      return true;
    });

    await _installFileMenu();
    await _installToolsMenu();
    await _installViewMenu();
    await _installCheckForUpdates();

    _installed = true;
    await _syncRecents();
    await _syncAppearance();
  }

  Future<void> _installToolsMenu() async {
    await MacMenuBar.addSubmenu(
      parentMenuId: 'main',
      submenuId: _toolsMenuId,
      title: 'Tools',
      index: 2,
    );

    await MacMenuBar.addMenuItem(
      menuId: _toolsMenuId,
      itemId: _manageToolsId,
      title: 'Manage Tools...',
      index: 0,
      systemImage: _manageToolsIcon,
    );
  }

  /// Puts "Check for Updates…" in the application menu, next to About.
  ///
  /// `mac_menu_bar` addresses menus by their NSMenu *title*. For the
  /// application menu that title is `APP_NAME` — the literal placeholder from
  /// `MainMenu.xib`, which nothing ever substitutes; macOS renders the menu
  /// using the bundle name instead, so users still read "App Studio".
  /// Verified by running the release build and reading the log line below.
  ///
  /// The product name is tried too, in case a future Flutter template starts
  /// substituting it, and the Tools menu is the last resort — we own that one
  /// outright. The item has to end up *somewhere*: a build with no way to check
  /// for updates is worse than one where the item sits in an odd place.
  String get _checkUpdatesLabel {
    final reason = updatesUnavailableReason();
    return reason == null ? _checkUpdatesTitle : 'Check for Updates ($reason)';
  }

  Future<void> _installCheckForUpdates() async {
    const candidates = ['APP_NAME', 'App Studio', 'AppStudio'];

    for (final menuId in candidates) {
      final added = await MacMenuBar.addMenuItem(
        menuId: menuId,
        itemId: _checkUpdatesId,
        // Index 1: directly under "About App Studio", above the separator.
        index: 1,
        title: _checkUpdatesLabel,
        systemImage: _checkUpdatesIcon,
        enabled: canCheckForUpdates(),
      );
      if (added) {
        debugPrint('MacAppMenu: Check for Updates installed in "$menuId" menu');
        await _addAutomaticUpdatesItem(menuId, index: 2);
        return;
      }
    }

    debugPrint(
      'MacAppMenu: could not reach the application menu; '
      'Check for Updates went to the Tools menu instead',
    );
    await MacMenuBar.addMenuSeparator(
      menuId: _toolsMenuId,
      itemId: 'tools_updates_sep',
      index: 1,
    );
    await MacMenuBar.addMenuItem(
      menuId: _toolsMenuId,
      itemId: _checkUpdatesId,
      title: _checkUpdatesLabel,
      index: 2,
      systemImage: _checkUpdatesIcon,
      enabled: canCheckForUpdates(),
    );
    await _addAutomaticUpdatesItem(_toolsMenuId, index: 3);
  }

  /// The "check automatically" preference, as a checked menu item.
  ///
  /// Deliberately not a switch in the settings dialog — that dialog is about
  /// AI providers, and Sparkle already owns this preference. A checked item
  /// next to the action it governs is the macOS-native place for it.
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

  void dispose() {
    session.removeListener(_sync);
    themeController.removeListener(_sync);
  }

  void _onItemSelected(String itemId) {
    switch (itemId) {
      case _newProjectId:
        onNewProject();
      case _manageToolsId:
        onManageTools();
      case _checkUpdatesId:
        onCheckForUpdates();
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
      default:
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
  }

  Future<void> _syncRecents() async {
    for (final id in _recentItemIds) {
      await MacMenuBar.removeMenuItem(id);
    }
    _recentItemIds = [];

    final recents = session.recents;
    await MacMenuBar.setMenuItemEnabled(_openRecentId, recents.isNotEmpty);

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
