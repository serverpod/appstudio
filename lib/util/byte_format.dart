const _units = ['bytes', 'kB', 'MB', 'GB', 'TB'];

/// Human-readable size, decimal SI so it matches what macOS reports.
///
/// One decimal below 10 of a unit (`1.5 GB`), none above (`132 MB`).
String formatBytes(int bytes) {
  if (bytes < 0) return '0 bytes';
  if (bytes < 1000) return '$bytes ${_units.first}';

  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1000 && unit < _units.length - 1) {
    value /= 1000;
    unit++;
  }

  // Rounding can push 999.95 MB up to 1000 MB — carry into the next unit.
  if (value >= 999.95 && unit < _units.length - 1) {
    value /= 1000;
    unit++;
  }

  final digits = value < 10 ? 1 : 0;
  var text = value.toStringAsFixed(digits);
  if (text.endsWith('.0')) text = text.substring(0, text.length - 2);
  return '$text ${_units[unit]}';
}
