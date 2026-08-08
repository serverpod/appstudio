library;

/// The user's home directory, or null where there is no such concept.
///
/// Behind a conditional import so [prettyPath] — which is pure string work —
/// does not drag `dart:io` into every widget that displays a path. The widget
/// preview environment compiles for web, where `Platform` does not exist.
export 'home_dir_stub.dart' if (dart.library.io) 'home_dir_io.dart';
