library;

/// Exits the app on platforms that support it; a no-op in the web preview.
export 'quit_app_stub.dart' if (dart.library.io) 'quit_app_io.dart';
