/// The artifact key for the platform we are running on.
///
/// Split behind a conditional import so the manifest model stays free of
/// `dart:io`. Widget previews and any other web-hosted tooling compile the
/// whole tool_status tree, and one `Platform.version` call would otherwise
/// drag `dart:io` through it.
library;

export 'platform_key_stub.dart'
    if (dart.library.io) 'platform_key_io.dart';
