/// Opens a URL in the user's browser.
///
/// Split behind a conditional import, like `quit_app.dart`, so the dialogs that
/// link out stay free of `dart:io`.
library;

export 'open_url_stub.dart' if (dart.library.io) 'open_url_io.dart';
