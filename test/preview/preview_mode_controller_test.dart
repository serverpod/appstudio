import 'dart:ui' show Brightness;

import 'package:appstudio/platform/compact_window.dart';
import 'package:appstudio/preview/preview_device.dart';
import 'package:appstudio/preview/preview_mode_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_compact_window.dart';

void main() {
  late FakeCompactWindow window;
  late PreviewModeController controller;
  late int notifications;

  setUp(() {
    window = FakeCompactWindow();
    controller = PreviewModeController(window: window);
    notifications = 0;
    controller.addListener(() => notifications++);
  });

  test('minimize in a phone mode enters the compact window', () {
    controller.minimize();

    expect(controller.minimized, isTrue);
    expect(controller.compactWindow, isTrue);
    expect(window.calls, ['enterCompact']);
    expect(notifications, 1);
  });

  test('expand restores the window', () {
    controller.minimize();
    controller.expand();

    expect(controller.minimized, isFalse);
    expect(controller.compactWindow, isFalse);
    expect(window.calls, ['enterCompact', 'exitCompact']);
  });

  test('without a compact window, a minimized phone view is desktop-minimized',
      () {
    // Windows, until the compact window is ported: the shell's chrome goes,
    // the window stays, and nothing is asked of a native side that is not
    // there.
    final plain = FakeCompactWindow(supportsCompactWindow: false);
    final mode = PreviewModeController(window: plain);

    mode.minimize();
    expect(mode.minimized, isTrue);
    expect(mode.compactWindow, isFalse);

    mode.setViewMode(PreviewViewMode.phoneLandscape);
    mode.expand();
    expect(mode.minimized, isFalse);
    expect(plain.calls, isEmpty);
  });

  test('expand when not minimized touches nothing', () {
    controller.expand();

    expect(window.calls, isEmpty);
    expect(notifications, 0);
  });

  test('minimized desktop hides chrome without a native window change', () {
    controller.setViewMode(PreviewViewMode.desktop);
    window.calls.clear();

    controller.minimize();

    expect(controller.minimized, isTrue);
    expect(controller.compactWindow, isFalse);
    expect(window.calls, isEmpty);

    controller.expand();
    expect(window.calls, isEmpty);
  });

  test('orientation flip while compact re-applies geometry', () {
    controller.minimize();

    controller.setViewMode(PreviewViewMode.phoneLandscape);

    expect(window.calls, ['enterCompact', 'updateGeometry']);
    final landscape = previewPhoneFrameSize(PreviewOrientation.landscape);
    expect(window.lastGeometry!.aspectWidth, landscape.width);
    expect(window.lastGeometry!.aspectHeight, landscape.height);
  });

  test('switching to desktop while compact restores the window, stays minimized',
      () {
    controller.minimize();

    controller.setViewMode(PreviewViewMode.desktop);

    expect(controller.minimized, isTrue);
    expect(controller.compactWindow, isFalse);
    expect(window.calls, ['enterCompact', 'exitCompact']);
  });

  test('switching back to phone while minimized re-enters the compact window',
      () {
    controller.setViewMode(PreviewViewMode.desktop);
    controller.minimize();
    window.calls.clear();

    controller.setViewMode(PreviewViewMode.phonePortrait);

    expect(controller.compactWindow, isTrue);
    expect(window.calls, ['enterCompact']);
  });

  test('brightness never touches the native window', () {
    controller.setPreviewBrightness(Brightness.dark);

    expect(controller.previewBrightness, Brightness.dark);
    expect(window.calls, isEmpty);
    expect(notifications, 1);
  });

  test('drag and resize forward to the platform', () async {
    controller.startWindowDrag();
    controller.startWindowResize(CompactResizeCorner.topLeft);
    controller.showResizeCursor(CompactResizeCorner.topRight);

    // The cursor call is deferred a microtask so it lands after the
    // framework's own cursor activation.
    expect(window.calls, ['startDrag', 'startResize:topLeft']);
    await Future<void>.delayed(Duration.zero);
    expect(
      window.calls,
      ['startDrag', 'startResize:topLeft', 'showResizeCursor:topRight'],
    );
  });

  test('geometry keeps the frame aspect and fixed chrome', () {
    final geometry = compactWindowGeometry(PreviewViewMode.phonePortrait);
    final frame = previewPhoneFrameSize(PreviewOrientation.portrait);

    expect(geometry.aspectWidth, frame.width);
    expect(geometry.aspectHeight, frame.height);
    expect(geometry.chromeWidth, kCompactFrameMargin * 2);
    expect(
      geometry.chromeHeight,
      kCompactFrameMargin * 2 + kCompactBarGap + kCompactBarHeight,
    );
  });
}
