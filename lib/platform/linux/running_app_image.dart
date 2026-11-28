import 'dart:io';

import 'package:path/path.dart' as p;

/// The AppImage this process runs from, or null when it runs from anything
/// else: a development build, a package, or another OS's build.
///
/// The AppImage runtime sets `$APPIMAGE` (the file) and `$APPDIR` (where the
/// image is mounted). Children inherit both, so a development build started
/// from a terminal inside another AppImage (an editor, say) sees that one's.
/// Only an [executable] inside the mount is this AppImage.
String? runningAppImage(Map<String, String> environment, String executable) {
  final appImage = environment['APPIMAGE'];
  final appDir = environment['APPDIR'];
  if (appImage == null || appImage.isEmpty) return null;
  if (appDir == null || appDir.isEmpty) return null;
  return p.isWithin(appDir, executable) ? appImage : null;
}

/// Starts [path] once the process [afterPid] (this one, by default) has
/// ended, so two copies of App Studio never run at once: they share the
/// preview's browser profile, which only one can hold. The caller quits
/// right after. A process that has not ended after 30 s is not waited for
/// any longer.
///
/// A detached `sh` does the waiting, since this process is the one going
/// away.
Future<void> startAfterExit(String path, {int? afterPid}) async {
  await Process.start('/bin/sh', [
    '-c',
    r'i=0; while kill -0 "$1" 2>/dev/null && [ "$i" -lt 150 ]; do '
        r'sleep 0.2; i=$((i + 1)); done; exec "$2"',
    'sh',
    '${afterPid ?? pid}',
    path,
  ], mode: ProcessStartMode.detached);
}
