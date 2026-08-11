import 'package:appstudio/platform/compact_window.dart';

/// Records compact-window calls instead of touching a native window.
class FakeCompactWindow implements CompactWindowPlatform {
  final calls = <String>[];
  CompactWindowGeometry? lastGeometry;

  @override
  Future<void> enterCompact(CompactWindowGeometry geometry) async {
    calls.add('enterCompact');
    lastGeometry = geometry;
  }

  @override
  Future<void> updateGeometry(CompactWindowGeometry geometry) async {
    calls.add('updateGeometry');
    lastGeometry = geometry;
  }

  @override
  Future<void> exitCompact() async {
    calls.add('exitCompact');
  }

  @override
  Future<void> startDrag() async {
    calls.add('startDrag');
  }

  @override
  Future<void> startResize(CompactResizeCorner corner) async {
    calls.add('startResize:${corner.name}');
  }

  @override
  Future<void> showResizeCursor(CompactResizeCorner corner) async {
    calls.add('showResizeCursor:${corner.name}');
  }
}
