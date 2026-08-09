import 'package:flutter/foundation.dart';

/// An external editor the open project can be handed to.
///
/// Deliberately holds no bundle path and no `IdeIntegration`: both live in
/// `dart:io` files, and the toolbar button only needs a name to draw and an id
/// to hand back.
@immutable
class ExternalEditor {
  const ExternalEditor({required this.id, required this.label});

  /// Matches `IdeIntegration.option` — the value `serverpod create --ide` takes.
  final String id;

  /// Shown on the button as “Open in [label]”.
  final String label;

  @override
  bool operator ==(Object other) =>
      other is ExternalEditor && other.id == id && other.label == label;

  @override
  int get hashCode => Object.hash(id, label);
}

/// Everything the toolbar's Open in … buttons need, and nothing that touches
/// the filesystem.
///
/// `ExternalEditorsController` implements this directly — no adapter — but the
/// buttons import only this file, so which editors are offered stays testable
/// without a real project on disk or a real editor installed.
abstract interface class ExternalEditorsView implements Listenable {
  /// Editors this project was configured for that are also installed on this
  /// Mac and can be handed a folder. Empty with no project open.
  List<ExternalEditor> get editors;

  /// False until the project is actually running.
  ///
  /// The buttons stay visible and go disabled rather than appearing when the
  /// project comes up: an editor opened on a project that is still compiling
  /// would attach to a server that cannot answer it, and a control that
  /// materialises minutes later is one the user never learns is there.
  bool get canOpen;

  /// Opens the current project in [editor]. Does nothing if the project closed
  /// in the meantime.
  Future<void> open(ExternalEditor editor);
}
