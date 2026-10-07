import 'ide_integration.dart';

/// Everything the New Project form does outside itself: pick a folder, run
/// `serverpod create`, and hand the result to the session.
///
/// `showNewProjectScreen` supplies the real one, built on `ProjectCreator` and
/// `ProjectSession`. The form takes only this, so each of its states — running,
/// failed, created but not configured — can be reached in Widgetbook and in
/// tests without spawning the CLI.
abstract interface class NewProjectView {
  /// Where the form starts: the last location used, or a sensible default.
  String get suggestedDirectory;

  /// Asks for a folder, starting at [current]. Null when the user cancelled.
  Future<String?> pickDirectory(String current);

  /// Creates the project and returns its path. Throws
  /// `ProjectCreationException` for a failure the form can explain.
  Future<String> create({
    required String name,
    required String parentDirectory,
    required Set<IdeIntegration> ides,
    void Function(String status)? onStatus,
  });

  /// Remembers [path] as the location for the next new project.
  Future<void> rememberDirectory(String path);

  /// Opens the project at [path], which starts it.
  void openProject(String path);
}
