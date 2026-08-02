import 'dart:io';

/// Shortens `$HOME/...` to `~/...` for display.
String prettyPath(String path) {
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) return path;
  if (path == home) return '~';
  if (path.startsWith('$home/')) return '~${path.substring(home.length)}';
  return path;
}
