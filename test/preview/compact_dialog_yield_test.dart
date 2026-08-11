import 'package:appstudio/preview/compact_dialog_yield.dart';
import 'package:appstudio/preview/preview_device.dart';
import 'package:appstudio/preview/preview_mode_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_compact_window.dart';

void main() {
  Route<void> route() => MaterialPageRoute(builder: (_) => const SizedBox());

  late FakeCompactWindow window;
  late PreviewModeController controller;
  late CompactDialogYield observer;

  setUp(() {
    window = FakeCompactWindow();
    controller = PreviewModeController(window: window);
    observer = CompactDialogYield(controller);
  });

  Future<void> flushMicrotasks() => Future<void>.delayed(Duration.zero);

  test('a route pushed over the compact window expands it', () async {
    controller.minimize();

    observer.didPush(route(), route());
    await flushMicrotasks();

    expect(controller.minimized, isFalse);
    expect(window.calls, ['enterCompact', 'exitCompact']);
  });

  test('the first route never expands — it is the compact content itself',
      () async {
    controller.minimize();

    observer.didPush(route(), null);
    await flushMicrotasks();

    expect(controller.minimized, isTrue);
  });

  test('minimized desktop keeps its dialogs — the window is normal there',
      () async {
    controller.setViewMode(PreviewViewMode.desktop);
    controller.minimize();

    observer.didPush(route(), route());
    await flushMicrotasks();

    expect(controller.minimized, isTrue);
    expect(window.calls, isEmpty);
  });

  test('does nothing when not minimized', () async {
    observer.didPush(route(), route());
    await flushMicrotasks();

    expect(controller.minimized, isFalse);
    expect(window.calls, isEmpty);
  });
}
