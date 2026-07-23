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
  }) {
    session.addListener(_sync);
    themeController.addListener(_sync);
  }

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
    await _installViewMenu();

    _installed = true;
    await _syncRecents();
    await _syncAppearance();
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

  void _sync() {
    if (!_installed) return;
    unawaited(MacMenuBar.setMenuItemEnabled(_closeId, session.hasProject));
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
