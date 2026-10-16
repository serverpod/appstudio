import 'home_dir.dart';

/// Shortens `$HOME/...` to `~/...` for display.
///
/// A Windows home (`C:\Users\alex`) is matched with its own separator and
/// without regard to case, as Windows compares paths; the rest of [path] is
/// shown as it is. [home] is for tests.
String prettyPath(String path, {String? home}) {
  home ??= homeDirectory();
  if (home == null || home.isEmpty) return path;
  final windows = home.contains(r'\');
  final separator = windows ? r'\' : '/';
  bool same(String a, String b) =>
      windows ? a.toLowerCase() == b.toLowerCase() : a == b;
  if (same(path, home)) return '~';
  if (path.length > home.length &&
      same(path.substring(0, home.length + 1), '$home$separator')) {
    return '~${path.substring(home.length)}';
  }
  return path;
}
