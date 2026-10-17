// Builds windows/runner/resources/app_icon.ico from the macOS app icon PNGs,
// so both platforms show the same icon from one source.
//
//   dart run tool/windows/make_icon.dart
//
// An .ico can hold PNG images directly (Windows Vista and later), so the
// PNGs go in unchanged: no resampling, no image library.
import 'dart:io';
import 'dart:typed_data';

const _source = 'macos/Runner/Assets.xcassets/AppIcon.appiconset';
const _target = 'windows/runner/resources/app_icon.ico';
const _sizes = [16, 32, 64, 128, 256];

void main() {
  final images = [
    for (final size in _sizes)
      File('$_source/app_icon_$size.png').readAsBytesSync(),
  ];
  final header = ByteData(6)
    ..setUint16(0, 0, Endian.little) // reserved
    ..setUint16(2, 1, Endian.little) // type: icon
    ..setUint16(4, images.length, Endian.little);
  final out = BytesBuilder()..add(header.buffer.asUint8List());
  var offset = 6 + 16 * images.length;
  for (final (i, png) in images.indexed) {
    final size = _sizes[i];
    final entry = ByteData(16)
      ..setUint8(0, size == 256 ? 0 : size) // 0 means 256
      ..setUint8(1, size == 256 ? 0 : size)
      ..setUint8(2, 0) // palette colours
      ..setUint8(3, 0) // reserved
      ..setUint16(4, 1, Endian.little) // colour planes
      ..setUint16(6, 32, Endian.little) // bits per pixel
      ..setUint32(8, png.length, Endian.little)
      ..setUint32(12, offset, Endian.little);
    out.add(entry.buffer.asUint8List());
    offset += png.length;
  }
  for (final png in images) {
    out.add(png);
  }
  File(_target).writeAsBytesSync(out.takeBytes());
  stdout.writeln('Wrote $_target (${_sizes.join(', ')} px).');
}
