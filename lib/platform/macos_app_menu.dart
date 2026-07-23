import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show SingleActivator;
import 'package:mac_menu_bar/mac_menu_bar.dart';
import 'package:path/path.dart' as p;

import '../agent/agent_controller.dart';
import '../process/serverpod_process.dart';
import '../session/project_session.dart';

/// Adds a File menu to the native macOS menu bar while preserving the
/// standard Edit/View/Window/Help items from MainMenu.xib.
class MacAppMenu {
  MacAppMenu({
    required this.session,
    required this.process,
    required this.agent,
    required this.onNewProject,
  }) {
    session.addListener(_sync);
  }

  static const _fileMenuId = 'file';
  static const _openRecentId = 'file_open_recent';
  static const _separatorId = 'file_sep';
  static const _newProjectIcon = 'plus';
  static const _openIcon = 'arrow.up.right';
  static const _openRecentIcon = 'clock';
  static const _closeIcon = 'xmark';
  static const _newProjectId = 'file_new_project';
  static const _openId = 'file_open';
  static const _closeId = 'file_close';

  final ProjectSession session;
  final ServerpodProcessController process;
  final AgentController agent;
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

    _installed = true;
    await _syncRecents();
  }

  void dispose() {
    session.removeListener(_sync);
  }

  void _onItemSelected(String itemId) {
    switch (itemId) {
      case _newProjectId:
        onNewProject();
      case _openId:
        unawaited(session.openProjectPicker());
      case _closeId:
        unawaited(_closeProject());
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
}
