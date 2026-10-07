/// Fakes for the views an open project's chrome reads: the start page's
/// recents, the Create Project form, and the toolbar's buttons.
library;

import 'dart:async';

import 'package:appstudio/process/full_restart_view.dart';
import 'package:appstudio/process/new_project_view.dart';
import 'package:appstudio/process/project_creator.dart';
import 'package:appstudio/process/project_ready_view.dart';
import 'package:appstudio/session/external_editors_view.dart';
import 'package:appstudio/session/recent_projects_view.dart';
import 'package:appstudio/util/home_dir.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Under the real home directory, so the UI shortens it to `~/…` exactly as
/// it does for a real path.
String homePath(String relative) => p.join(homeDirectory() ?? '/Users/you', relative);

class FakeRecentProjects extends ChangeNotifier implements RecentProjectsView {
  FakeRecentProjects({List<String> recents = const [], this.error})
      : _recents = [...recents];

  List<String> _recents;

  @override
  List<String> get recents => List.unmodifiable(_recents);

  @override
  String? error;

  @override
  Future<void> openProjectPicker() async {}

  @override
  Future<void> openPath(String path) async {}

  @override
  Future<void> clearRecents() async {
    _recents = [];
    notifyListeners();
  }
}

/// How [FakeNewProject.create] ends.
enum CreateOutcome {
  /// Walks through the CLI's status lines, then succeeds.
  succeeds,

  /// Never finishes — the progress view, held.
  hangs,

  /// `serverpod create` fails, with its output.
  fails,

  /// The project reached disk but could not be configured for the preview.
  partlyCreated,
}

class FakeNewProject implements NewProjectView {
  FakeNewProject({this.outcome = CreateOutcome.succeeds});

  final CreateOutcome outcome;

  @override
  String get suggestedDirectory => homePath('Projects');

  @override
  Future<String?> pickDirectory(String current) async =>
      homePath('Projects/clients');

  @override
  Future<String> create({
    required String name,
    required String parentDirectory,
    required Set<IdeIntegration> ides,
    void Function(String status)? onStatus,
  }) async {
    final path = p.join(parentDirectory, name);
    switch (outcome) {
      case CreateOutcome.hangs:
        onStatus?.call('Resolving dependencies…');
        return Completer<String>().future;
      case CreateOutcome.fails:
        throw ProjectCreationException(
          'serverpod create failed (exit code 1).',
          log: 'Creating project "$name"…\n'
              'Error: Directory $path already exists and is not empty.\n'
              'Pick another name or location and try again.',
        );
      case CreateOutcome.partlyCreated:
        throw ProjectCreationException(
          'The project was created, but App Studio could not configure its '
          'preview. It may open in a browser instead of the preview pane.',
          createdPath: path,
        );
      case CreateOutcome.succeeds:
        for (final status in const [
          'Creating project…',
          'Resolving dependencies…',
          'Generating code…',
          'Configuring preview…',
        ]) {
          onStatus?.call(status);
          await Future<void>.delayed(const Duration(milliseconds: 900));
        }
        return path;
    }
  }

  @override
  Future<void> rememberDirectory(String path) async {}

  @override
  void openProject(String path) {}
}

class FakeProjectReady extends ChangeNotifier implements ProjectReadyView {
  FakeProjectReady({this.projectIsReady = false});

  @override
  bool projectIsReady;
}

/// Restarts for two seconds, then is running again.
class FakeFullRestart extends ChangeNotifier implements FullRestartView {
  FakeFullRestart({this.isTransitioning = false, this.isStopped = false});

  @override
  bool isTransitioning;

  @override
  bool isStopped;

  @override
  bool get canRestart => !isTransitioning;

  @override
  Future<void> restart() async {
    isTransitioning = true;
    notifyListeners();
    await Future<void>.delayed(const Duration(seconds: 2));
    isTransitioning = false;
    isStopped = false;
    notifyListeners();
  }
}

class FakeExternalEditors extends ChangeNotifier implements ExternalEditorsView {
  FakeExternalEditors({this.editors = const [], this.canOpen = true});

  @override
  final List<ExternalEditor> editors;

  @override
  final bool canOpen;

  @override
  Future<void> open(ExternalEditor editor) async {}
}

const cursorEditor = ExternalEditor(id: 'cursor', label: 'Cursor');
const claudeEditor = ExternalEditor(id: 'claude', label: 'Claude Code');
const vscodeEditor = ExternalEditor(id: 'vscode', label: 'VS Code');
