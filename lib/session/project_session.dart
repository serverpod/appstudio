import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class ProjectSession extends ChangeNotifier {
  ProjectSession();

  static const _recentsKey = 'recent_projects';
  static const _maxRecents = 5;
  static final previewUri = Uri.parse('http://localhost:9998');

  String? _projectPath;
  String? _error;
  List<String> _recents = [];

  String? get projectPath => _projectPath;
  String? get error => _error;
  List<String> get recents => List.unmodifiable(_recents);
  bool get hasProject => _projectPath != null;

  String? get projectName =>
      _projectPath == null ? null : p.basename(_projectPath!);

  void closeProject() {
    if (_projectPath == null) return;
    _projectPath = null;
    _error = null;
    notifyListeners();
  }

  Future<void> loadRecents() async {
    final prefs = await SharedPreferences.getInstance();
    _recents = prefs.getStringList(_recentsKey) ?? [];
    notifyListeners();
  }

  Future<void> clearRecents() async {
    if (_recents.isEmpty) return;
    _recents = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentsKey, _recents);
    notifyListeners();
  }

  Future<void> openProjectPicker() async {
    final path = await getDirectoryPath(confirmButtonText: 'Open Project');
    if (path == null) return;
    await openPath(path);
  }

  Future<void> openPath(String path) async {
    _error = null;
    final normalized = p.normalize(path);
    final validRoot = await _findServerpodRoot(normalized);
    if (validRoot == null) {
      _error =
          'Not a Serverpod project. Open a folder with a pubspec that depends on serverpod.';
      notifyListeners();
      return;
    }
    _projectPath = validRoot;
    await _remember(validRoot);
    notifyListeners();
  }

  Future<void> _remember(String path) async {
    final next = [path, ..._recents.where((e) => e != path)];
    if (next.length > _maxRecents) {
      next.removeRange(_maxRecents, next.length);
    }
    _recents = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentsKey, _recents);
  }

  Future<String?> _findServerpodRoot(String path) async {
    if (await _isServerpodPackage(path)) return path;

    final dir = Directory(path);
    if (!await dir.exists()) return null;

    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! Directory) continue;
      if (await _isServerpodPackage(entity.path)) return path;
    }
    return null;
  }

  Future<bool> _isServerpodPackage(String dirPath) async {
    final pubspec = File(p.join(dirPath, 'pubspec.yaml'));
    if (!await pubspec.exists()) return false;
    final text = await pubspec.readAsString();
    return RegExp(
      r'^\s*(serverpod|serverpod_cli|serverpod_client)\s*:',
      multiLine: true,
    ).hasMatch(text);
  }
}
