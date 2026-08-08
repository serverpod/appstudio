/// Used where `dart:io` does not exist — the widget preview environment.
///
/// Reports the platform App Studio actually ships on, rather than
/// `unsupported`, so previews of the tools UI show real artifact sizes
/// instead of "not available for this Mac".
String currentPlatformKey() => 'macos-arm64';
