import 'dart:io';

import 'package:flutter/services.dart';

/// Thin bridge to macOS UserNotifications (main app only).
///
/// Permission is requested lazily on first [show] — not at launch — so CEF's
/// Helper (Alerts) is not needed for App Studio's own alerts.
class StudioNotifications {
  StudioNotifications._();

  static const _channel = MethodChannel('dev.serverpod.appstudio/notifications');

  /// Posts a notification. On macOS, skipped when the app is frontmost unless
  /// [force] is true. No-ops on other platforms.
  static Future<void> show({
    required String title,
    required String body,
    bool force = false,
  }) async {
    if (!Platform.isMacOS) return;
    try {
      await _channel.invokeMethod<void>('show', {
        'title': title,
        'body': body,
        'force': force,
      });
    } on PlatformException {
      // Best-effort — missing plugin wiring or denied permission.
    }
  }

  static Future<void> agentTaskCompleted({String? summary}) {
    final body = (summary == null || summary.trim().isEmpty)
        ? 'Agent finished working.'
        : summary.trim();
    return show(title: 'App Studio', body: body);
  }
}
