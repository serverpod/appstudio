import 'dart:io';

import '../platform/host.dart';
import '../platform/windows/win32_system.dart';

/// `open` hands the URL to LaunchServices, which picks the user's browser.
/// On Windows `ShellExecute` does the same through the registered handler, and
/// on Linux `xdg-open` through the desktop's default handlers.
Future<void> openUrl(Uri url) async {
  try {
    if (currentHost.isWindows) {
      Win32System().shellOpen(url.toString());
      return;
    }
    if (currentHost.isLinux) {
      // Found on PATH: it is /usr/bin/xdg-open on every desktop distro, but
      // an absolute path would be one more thing to be wrong about.
      await Process.run('xdg-open', [url.toString()]);
      return;
    }
    await Process.run('/usr/bin/open', [url.toString()]);
  } catch (_) {
    // Nothing useful to report: the link text is still on screen.
  }
}
