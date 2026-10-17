import 'dart:io';

import '../platform/host.dart';
import '../platform/windows/win32_system.dart';

/// `open` hands the URL to LaunchServices, which picks the user's browser.
/// On Windows `ShellExecute` does the same through the registered handler.
Future<void> openUrl(Uri url) async {
  try {
    if (currentHost.isWindows) {
      Win32System().shellOpen(url.toString());
      return;
    }
    await Process.run('/usr/bin/open', [url.toString()]);
  } catch (_) {
    // Nothing useful to report: the link text is still on screen.
  }
}
