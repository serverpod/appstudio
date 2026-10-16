import 'dart:io';

/// `macos-arm64`, `macos-x64`, `windows-arm64`, `windows-x64`, or
/// `unsupported`.
String currentPlatformKey() {
  final os = switch (Platform.operatingSystem) {
    'macos' => 'macos',
    'windows' => 'windows',
    _ => null,
  };
  if (os == null) return 'unsupported';
  // Platform.version reads e.g. "3.12.2 ... (macos_arm64)".
  return Platform.version.contains('arm64') ? '$os-arm64' : '$os-x64';
}

/// The CPU half of [currentPlatformKey]: `arm64` or `x64`.
String currentArch() =>
    currentPlatformKey().endsWith('-arm64') ? 'arm64' : 'x64';
