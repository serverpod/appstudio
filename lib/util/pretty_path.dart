import 'home_dir.dart';

/// Shortens `$HOME/...` to `~/...` for display.
String prettyPath(String path) {
  final home = homeDirectory();
  if (home == null || home.isEmpty) return path;
  if (path == home) return '~';
  if (path.startsWith('$home/')) return '~${path.substring(home.length)}';
  return path;
}
