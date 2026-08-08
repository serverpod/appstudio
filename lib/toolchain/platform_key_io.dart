import 'dart:io';

/// `macos-arm64`, `macos-x64`, or `unsupported`.
String currentPlatformKey() {
  if (!Platform.isMacOS) return 'unsupported';
  // Platform.version reads e.g. "3.12.2 ... (macos_arm64)".
  return Platform.version.contains('arm64') ? 'macos-arm64' : 'macos-x64';
}
