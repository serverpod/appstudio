import 'dart:io';

/// `open` hands the URL to LaunchServices, which picks the user's browser.
Future<void> openUrl(Uri url) async {
  try {
    await Process.run('/usr/bin/open', [url.toString()]);
  } catch (_) {
    // Nothing useful to report: the link text is still on screen.
  }
}
