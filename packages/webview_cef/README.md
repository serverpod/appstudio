# webview_cef (App Studio fork)

Local fork of [webview_cef](https://github.com/hlwhl/webview_cef) **0.5.1** used by App Studio.

## App Studio changes

- **Resize / surface sync** — more reliable CEF surface sizing when the preview pane or device mode changes (`lib/src/webview.dart`).
- **No Helper (Alerts)** — `macos/scripts/embed_cef_helpers.sh` skips embedding `* Helper (Alerts).app` so macOS does not show a second notification-permission dialog for Chromium alerts.

## CEF binaries

Not committed. `pod install` runs `macos/scripts/download_cef.sh`, which populates `macos/third/cef/` (gitignored).

## Upstream

- Package: https://pub.dev/packages/webview_cef
- Repo: https://github.com/hlwhl/webview_cef
